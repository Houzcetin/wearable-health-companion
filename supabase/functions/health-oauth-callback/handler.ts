import { exchangeCode, GoogleHealthClient } from "../_shared/google.ts";
import { verifyState } from "../_shared/state.ts";
import { createServiceClient, requireEnv } from "../_shared/supabase.ts";

type Failure =
  | "denied"
  | "bad_state"
  | "no_refresh_token"
  | "exchange_failed"
  | "identity_failed"
  | "not_linked"
  | "store_failed";

function errorCode(error: unknown): string {
  return error instanceof Error ? (error as { code?: string }).code ?? error.name : "unknown";
}

function redirect(reason?: Failure, detail?: string): Response {
  // Reason codes only; never tokens or provider bodies.
  if (reason) {
    console.warn(`health-oauth-callback failed: ${reason}${detail ? ` (${detail})` : ""}`);
  }
  const url = new URL("wearablecompanion://connected");
  url.searchParams.set("status", reason ? "error" : "ok");
  if (reason) url.searchParams.set("reason", reason);
  return new Response(null, {
    status: 302,
    headers: { Location: url.toString(), "Cache-Control": "no-store" },
  });
}

export async function handler(req: Request): Promise<Response> {
  if (req.method !== "GET") return new Response(null, { status: 405, headers: { Allow: "GET" } });
  const params = new URL(req.url).searchParams;
  let userId: string;
  try {
    userId =
      (await verifyState(params.get("state") ?? "", requireEnv("OAUTH_STATE_SECRET"))).userId;
  } catch {
    return redirect("bad_state");
  }
  if (params.has("error")) return redirect("denied");
  const code = params.get("code");
  if (!code) return redirect("exchange_failed");
  let tokens;
  try {
    tokens = await exchangeCode(code, {
      clientId: requireEnv("GOOGLE_OAUTH_CLIENT_ID"),
      clientSecret: requireEnv("GOOGLE_OAUTH_CLIENT_SECRET"),
      redirectUri: `${
        requireEnv("SUPABASE_URL").replace(/\/$/, "")
      }/functions/v1/health-oauth-callback`,
    });
  } catch (error) {
    return redirect("exchange_failed", errorCode(error));
  }
  if (!tokens.refreshToken) return redirect("no_refresh_token");
  let healthUserId: string;
  try {
    healthUserId = await new GoogleHealthClient(tokens.accessToken).getIdentity();
  } catch (error) {
    const code = errorCode(error);
    return redirect(code === "google_not_linked" ? "not_linked" : "identity_failed", code);
  }
  try {
    const client = createServiceClient();
    const { error } = await client.rpc("store_health_connection", {
      p_user_id: userId,
      p_health_user_id: healthUserId,
      p_refresh_token: tokens.refreshToken,
      p_scopes: tokens.scopes,
    });
    if (error) return redirect("store_failed", error.code);
    const queued = await client.rpc("enqueue_backfill", { p_user_id: userId, p_days: 35 });
    if (queued.error) return redirect("store_failed", queued.error.code);
    return redirect();
  } catch (error) {
    return redirect("store_failed", errorCode(error));
  }
}
