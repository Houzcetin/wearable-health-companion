import { GOOGLE_SCOPES } from "../_shared/google.ts";
import { signState } from "../_shared/state.ts";
import {
  errorResponse,
  jsonResponse,
  preflightOrMethod,
  requireEnv,
  requireUserId,
} from "../_shared/supabase.ts";

export async function handler(req: Request): Promise<Response> {
  const early = preflightOrMethod(req);
  if (early) return early;
  try {
    const userId = await requireUserId(req);
    const url = new URL("https://accounts.google.com/o/oauth2/v2/auth");
    url.search = new URLSearchParams({
      client_id: requireEnv("GOOGLE_OAUTH_CLIENT_ID"),
      redirect_uri: `${
        requireEnv("SUPABASE_URL").replace(/\/$/, "")
      }/functions/v1/health-oauth-callback`,
      response_type: "code",
      access_type: "offline",
      prompt: "consent",
      include_granted_scopes: "true",
      scope: GOOGLE_SCOPES.join(" "),
      state: await signState({ userId, ttlSeconds: 600 }, requireEnv("OAUTH_STATE_SECRET")),
    }).toString();
    return jsonResponse({ url: url.toString() });
  } catch (error) {
    return errorResponse(error);
  }
}
