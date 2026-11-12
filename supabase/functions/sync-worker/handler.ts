import { GoogleHealthClient, refreshAccessToken } from "../_shared/google.ts";
import { createQueueStore } from "../_shared/queue.ts";
import {
  bearerToken,
  createServiceClient,
  errorResponse,
  jsonResponse,
  preflightOrMethod,
  requireEnv,
  requireUserId,
  sameSecret,
} from "../_shared/supabase.ts";
import { runWorker } from "../_shared/worker.ts";

export async function handler(req: Request): Promise<Response> {
  const early = preflightOrMethod(req);
  if (early) return early;
  try {
    const cronSecret = Deno.env.get("SYNC_CRON_SECRET");
    const isCron = !!cronSecret?.trim() &&
      sameSecret(req.headers.get("x-cron-secret") ?? "", cronSecret);
    if (!isCron) {
      const token = bearerToken(req);
      if (!sameSecret(token, requireEnv("SUPABASE_SERVICE_ROLE_KEY"))) await requireUserId(req);
    }
    const client = createServiceClient();
    const store = createQueueStore(client);
    const config = {
      clientId: requireEnv("GOOGLE_OAUTH_CLIENT_ID"),
      clientSecret: requireEnv("GOOGLE_OAUTH_CLIENT_SECRET"),
    };
    return jsonResponse(
      await runWorker({
        store,
        async healthForUser(userId, context, signal) {
          const tokens = await refreshAccessToken(context.refreshToken, config, fetch, signal);
          if (tokens.refreshToken && tokens.refreshToken !== context.refreshToken) {
            await store.rotateToken(userId, context, tokens.refreshToken, tokens.scopes);
          }
          return new GoogleHealthClient(tokens.accessToken, fetch, signal);
        },
      }),
    );
  } catch (error) {
    return errorResponse(error);
  }
}
