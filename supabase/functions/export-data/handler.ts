import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import {
  createServiceClient,
  errorResponse,
  HttpError,
  jsonResponse,
  preflightOrMethod,
  requireUserId,
} from "../_shared/supabase.ts";

interface Dependencies {
  db?: SupabaseClient;
  userId?: typeof requireUserId;
  now?: () => number;
}
function check(error: unknown): void {
  if (error) throw new HttpError(500, "export_failed");
}

export async function handler(req: Request, deps: Dependencies = {}): Promise<Response> {
  const early = preflightOrMethod(req);
  if (early) return early;
  try {
    const userId = await (deps.userId ?? requireUserId)(req);
    const db = deps.db ?? createServiceClient();
    const rows = async (table: string, order: string, secondaryOrder?: string) => {
      const all: Record<string, unknown>[] = [];
      for (let offset = 0;; offset += 1000) {
        let query = db.from(table).select("*").eq("user_id", userId).order(order);
        if (secondaryOrder) query = query.order(secondaryOrder);
        const result = await query.range(offset, offset + 999);
        check(result.error);
        const page = (result.data ?? []) as Record<string, unknown>[];
        all.push(...page);
        if (page.length < 1000) return all;
      }
    };
    const [user, profile, connection, consent, metrics, messages, workouts] = await Promise.all([
      db.auth.admin.getUserById(userId),
      db.from("profiles").select("*").eq("user_id", userId).maybeSingle(),
      db.from("health_connections").select("status,connected_at,last_synced_at,scopes")
        .eq("user_id", userId).maybeSingle(),
      rows("consent_events", "id"),
      rows("daily_metrics", "date"),
      rows("coach_messages", "id"),
      rows("workouts", "started_at", "id"),
    ]);
    check(user.error);
    check(profile.error);
    check(connection.error);
    if (!user.data.user) throw new HttpError(401, "unauthorized");
    const health = connection.data;
    return jsonResponse({
      exported_at: new Date((deps.now ?? Date.now)()).toISOString(),
      user: { id: user.data.user.id, email: user.data.user.email ?? null },
      profile: profile.data,
      consent_events: consent,
      health_connection: health
        ? {
          status: health.status,
          connected_at: health.connected_at,
          last_synced_at: health.last_synced_at,
          scopes: health.scopes,
        }
        : null,
      daily_metrics: metrics,
      coach_messages: messages,
      workouts,
    });
  } catch (error) {
    return errorResponse(error);
  }
}
