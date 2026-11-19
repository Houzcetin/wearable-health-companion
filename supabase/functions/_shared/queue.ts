import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import type { MetricsUpdate } from "./mapping.ts";

export interface SyncJob {
  id: number | string;
  user_id: string;
  data_type: string;
  date: string;
  attempts: number;
}

export interface UserContext {
  timeZone: string;
  refreshToken: string;
  healthUserId: string;
  scopes: string[];
}

export interface QueueStore {
  claim(size: number): Promise<SyncJob[]>;
  userContext(userId: string): Promise<UserContext>;
  upsert(userId: string, date: string, metrics: MetricsUpdate): Promise<void>;
  done(jobs: SyncJob[]): Promise<void>;
  retry(job: SyncJob, code: string, runAfter: string | null): Promise<void>;
  release(job: SyncJob): Promise<void>;
  revoke(userId: string): Promise<void>;
  synced(userId: string): Promise<void>;
  remaining(): Promise<number>;
  rotateToken(userId: string, context: UserContext, token: string, scopes: string[]): Promise<void>;
}

export class QueueError extends Error {
  constructor(public code: string, public transient = true) {
    super(code);
  }
}

function check(error: { code?: string } | null): void {
  if (error) throw new QueueError("database_error");
}

export function createQueueStore(client: SupabaseClient, userId?: string): QueueStore {
  async function returnToPending(job: SyncJob, fields: Record<string, unknown>): Promise<void> {
    const { error } = await client.from("sync_queue").update({ status: "pending", ...fields })
      .eq("id", job.id).eq("status", "running");
    if (error?.code === "23505") {
      // A webhook may have enqueued the same date while this row was running. Keep its pending row.
      const duplicate = await client.from("sync_queue").select("id").eq("user_id", job.user_id)
        .eq("data_type", job.data_type).eq("date", job.date).eq("status", "pending").maybeSingle();
      check(duplicate.error);
      if (!duplicate.data) throw new QueueError("queue_retry_conflict");
      const finished = await client.from("sync_queue").update({
        status: "done",
        last_error: "superseded_by_pending",
      }).eq("id", job.id).eq("status", "running");
      check(finished.error);
    } else check(error);
  }

  return {
    async claim(size) {
      const { data, error } = await client.rpc("claim_sync_jobs", {
        batch_size: size,
        ...(userId === undefined ? {} : { p_user_id: userId }),
      });
      check(error);
      if (!Array.isArray(data)) throw new QueueError("queue_response");
      return data as SyncJob[];
    },
    async userContext(userId) {
      const profile = await client.from("profiles").select("timezone,health_consent_at")
        .eq("user_id", userId).maybeSingle();
      check(profile.error);
      if (!profile.data?.health_consent_at) {
        throw new QueueError("health_consent_required", false);
      }
      const [connection, token] = await Promise.all([
        client.from("health_connections").select("status,health_user_id,scopes").eq(
          "user_id",
          userId,
        ).maybeSingle(),
        client.rpc("get_health_refresh_token", { p_user_id: userId }),
      ]);
      check(connection.error);
      check(token.error);
      if (connection.data?.status !== "active") throw new QueueError("connection_inactive", false);
      if (typeof token.data !== "string" || !token.data) {
        throw new QueueError("refresh_token_missing", false);
      }
      const timeZone = profile.data?.timezone ?? "UTC";
      try {
        new Intl.DateTimeFormat("en", { timeZone }).format();
      } catch {
        throw new QueueError("invalid_timezone", false);
      }
      return {
        timeZone,
        refreshToken: token.data,
        healthUserId: connection.data.health_user_id,
        scopes: connection.data.scopes,
      };
    },
    async upsert(userId, date, metrics) {
      if (!Object.keys(metrics).length) return;
      // A single sparse object makes PostgREST update only these supplied columns on conflict.
      const { error } = await client.from("daily_metrics").upsert({
        user_id: userId,
        date,
        ...metrics,
        source_updated_at: new Date().toISOString(),
        is_demo: false,
      }, { onConflict: "user_id,date", defaultToNull: false });
      check(error);
    },
    async done(jobs) {
      if (!jobs.length) return;
      const { error } = await client.from("sync_queue").update({ status: "done", last_error: null })
        .in("id", jobs.map((job) => job.id)).eq("status", "running");
      check(error);
    },
    async retry(job, code, runAfter) {
      if (runAfter) await returnToPending(job, { run_after: runAfter, last_error: code });
      else {
        const { error } = await client.from("sync_queue").update({
          status: "failed",
          last_error: code,
        })
          .eq("id", job.id).eq("status", "running");
        check(error);
      }
    },
    async release(job) {
      await returnToPending(job, { attempts: Math.max(0, job.attempts - 1) });
    },
    async revoke(userId) {
      const connection = await client.from("health_connections").update({
        status: "revoked",
        last_error: "invalid_grant",
      }).eq("user_id", userId);
      check(connection.error);
      const jobs = await client.from("sync_queue").update({
        status: "failed",
        last_error: "invalid_grant",
      })
        .eq("user_id", userId).in("status", ["pending", "running"]);
      check(jobs.error);
    },
    async synced(userId) {
      const outstanding = await client.from("sync_queue").select("id", {
        count: "exact",
        head: true,
      })
        .eq("user_id", userId).in("status", ["pending", "running"]);
      check(outstanding.error);
      if (outstanding.count !== 0) return;
      const { error } = await client.from("health_connections").update({
        last_synced_at: new Date().toISOString(),
        last_error: null,
      }).eq("user_id", userId).eq("status", "active");
      check(error);
    },
    async remaining() {
      let query = client.from("sync_queue").select("id", {
        count: "exact",
        head: true,
      })
        .in("status", ["pending", "running"]);
      if (userId !== undefined) query = query.eq("user_id", userId);
      const { count, error } = await query;
      check(error);
      return count ?? 0;
    },
    async rotateToken(userId, context, token, scopes) {
      const { error } = await client.rpc("store_health_connection", {
        p_user_id: userId,
        p_health_user_id: context.healthUserId,
        p_refresh_token: token,
        p_scopes: scopes.length ? scopes : context.scopes,
      });
      check(error);
    },
  };
}
