import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { record } from "../_shared/google.ts";
import {
  createServiceClient,
  errorResponse,
  HttpError,
  jsonResponse,
  preflightOrMethod,
  requireUserId,
  timedFetch,
} from "../_shared/supabase.ts";

interface Dependencies {
  db?: SupabaseClient;
  userId?: typeof requireUserId;
  fetcher?: typeof fetch;
}
function check(error: unknown): void {
  if (error) throw new HttpError(500, "delete_failed");
}

export async function handler(req: Request, deps: Dependencies = {}): Promise<Response> {
  const early = preflightOrMethod(req);
  if (early) return early;
  try {
    const userId = await (deps.userId ?? requireUserId)(req);
    let scope: unknown;
    try {
      scope = record(await req.json()).scope;
    } catch {
      throw new HttpError(400, "invalid_scope");
    }
    if (scope !== "health" && scope !== "account") throw new HttpError(400, "invalid_scope");
    const db = deps.db ?? createServiceClient();
    const token = await db.rpc("get_health_refresh_token", { p_user_id: userId });
    check(token.error);
    if (typeof token.data === "string" && token.data) {
      try {
        const response = await (deps.fetcher ?? timedFetch)(
          "https://oauth2.googleapis.com/revoke",
          {
            method: "POST",
            headers: { "Content-Type": "application/x-www-form-urlencoded" },
            body: new URLSearchParams({ token: token.data }),
          },
        );
        if (!response.ok) console.warn(response.status);
        // Consume the response without retaining or logging a provider body.
        await response.body?.cancel();
      } catch {
        console.warn("revoke_transport_failed");
      }
    }
    const deleted = await db.rpc("delete_user_health_data", { p_user_id: userId });
    check(deleted.error);
    if (scope === "account") {
      const consent = await db.from("consent_events").delete().eq("user_id", userId);
      check(consent.error);
      const account = await db.auth.admin.deleteUser(userId);
      check(account.error);
    } else {
      // apply_consent_event() clears profiles.health_consent_at when granted is false.
      const consent = await db.from("consent_events").insert({
        user_id: userId,
        kind: "health_data",
        granted: false,
      });
      check(consent.error);
    }
    return jsonResponse({ deleted: scope });
  } catch (error) {
    return errorResponse(error);
  }
}
