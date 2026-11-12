import { addDays, dateParts } from "../_shared/dates.ts";
import { record } from "../_shared/google.ts";
import { isDataType } from "../_shared/mapping.ts";
import {
  createServiceClient,
  errorResponse,
  HttpError,
  jsonResponse,
  preflightOrMethod,
  requireEnv,
  sameSecret,
} from "../_shared/supabase.ts";
import { createWebhookVerifier, verifyWebhookSignature } from "../_shared/webhook_signature.ts";

type EnqueueArgs = { p_health_user_id: string; p_data_type: string; p_dates: string[] };
interface Dependencies {
  fetcher?: typeof fetch;
  rpc?: (name: "enqueue_webhook_job", args: EnqueueArgs) => PromiseLike<{ error: unknown }>;
  secret?: () => string;
}

function intervalDates(value: unknown, sleep: boolean): string[] {
  const interval = record(record(value).civilIso8601TimeInterval);
  if (typeof interval.startTime !== "string" || typeof interval.endTime !== "string") return [];
  if (
    !/^\d{4}-\d{2}-\d{2}T/.test(interval.startTime) ||
    !/^\d{4}-\d{2}-\d{2}T/.test(interval.endTime)
  ) return [];
  const start = interval.startTime.slice(0, 10);
  const end = interval.endTime.slice(0, 10);
  try {
    dateParts(start);
    dateParts(end);
  } catch {
    return [];
  }
  if (end < start) return [];
  // Preserve the wake-up date even if a malformed/long sleep interval hits the cap.
  const dates = new Set<string>(sleep ? [end] : []);
  for (let date = start; date <= end && dates.size < 14; date = addDays(date, 1)) dates.add(date);
  return [...dates];
}

export function createHandler(deps: Dependencies = {}) {
  const verify = deps.fetcher ? createWebhookVerifier(deps.fetcher) : verifyWebhookSignature;
  return async (req: Request): Promise<Response> => {
    const early = preflightOrMethod(req);
    if (early) return early;
    try {
      const secret = (deps.secret ?? (() => requireEnv("HEALTH_WEBHOOK_SECRET")))();
      if (!secret.trim()) throw new HttpError(500, "missing_HEALTH_WEBHOOK_SECRET");
      if (!sameSecret(req.headers.get("Authorization") ?? "", "Bearer " + secret)) {
        throw new HttpError(401, "unauthorized");
      }
      const bytes = new Uint8Array(await req.arrayBuffer());
      const text = new TextDecoder().decode(bytes);
      // Google's verification POST carries our secret but no signature. It is
      // harmless to answer it for any caller that already holds the secret.
      if (/^\s*\{\s*"type"\s*:\s*"verification"\s*\}\s*$/.test(text)) return jsonResponse({});
      if (!await verify(bytes, req.headers.get("GOOGLE-HEALTH-API-SIGNATURE"))) {
        throw new HttpError(401, "invalid_signature");
      }
      let payload: unknown;
      try {
        payload = JSON.parse(text);
      } catch {
        console.warn("webhook_malformed_json");
        return new Response(null, { status: 204 });
      }
      const items = Array.isArray(payload) ? payload : [payload];
      if (items.length > 99) {
        console.warn("webhook_batch_limit");
        return new Response(null, { status: 204 });
      }
      const groups = new Map<string, EnqueueArgs>();
      for (const item of items) {
        const data = record(record(item).data);
        if (
          !["UPSERT", "DELETE"].includes(String(data.operation)) ||
          typeof data.healthUserId !== "string" || !data.healthUserId ||
          typeof data.dataType !== "string" || !isDataType(data.dataType) ||
          !Array.isArray(data.intervals)
        ) continue;
        const key = JSON.stringify([data.healthUserId, data.dataType]);
        const group = groups.get(key) ?? {
          p_health_user_id: data.healthUserId,
          p_data_type: data.dataType,
          p_dates: [],
        };
        const dates = new Set(group.p_dates);
        for (const interval of data.intervals) {
          for (const date of intervalDates(interval, data.dataType === "sleep")) dates.add(date);
        }
        // For sleep, retain the latest wake dates when a group exceeds 14 dates.
        const sorted = [...dates].sort();
        group.p_dates = data.dataType === "sleep" ? sorted.slice(-14) : sorted.slice(0, 14);
        groups.set(key, group);
      }
      if (groups.size) {
        const rpc = deps.rpc ?? ((name, args) => createServiceClient().rpc(name, args));
        for (const args of groups.values()) {
          if (!args.p_dates.length) continue;
          const { error } = await rpc("enqueue_webhook_job", args);
          if (error) throw new HttpError(500, "webhook_enqueue_failed");
        }
      }
      return new Response(null, { status: 204 });
    } catch (error) {
      return errorResponse(error);
    }
  };
}

export const handler = createHandler();
