// deno-lint-ignore-file require-await
// Transport doubles implement async interfaces without performing I/O.
import { handler as start } from "../health-oauth-start/handler.ts";
import { handler as callback } from "../health-oauth-callback/handler.ts";
import { handler as sync } from "../sync-worker/handler.ts";
import { GOOGLE_SCOPES } from "./google.ts";
import { signState, verifyState } from "./state.ts";
import { assert, assertEquals } from "./test_helpers.ts";

const settings: Record<string, string> = {
  SUPABASE_URL: "https://project.example.test",
  SUPABASE_ANON_KEY: "test-anon-key",
  SUPABASE_SERVICE_ROLE_KEY: "test-service-key",
  GOOGLE_OAUTH_CLIENT_ID: "test-client",
  GOOGLE_OAUTH_CLIENT_SECRET: "test-secret",
  OAUTH_STATE_SECRET: "test-state-secret",
};
const userId = "00000000-0000-4000-8000-000000000001";

async function mocked(fetcher: typeof fetch, run: () => Promise<void>): Promise<void> {
  const originalGet = Deno.env.get;
  const originalFetch = globalThis.fetch;
  // All configuration and transport are synthetic; do not read the host environment.
  Deno.env.get = (name) => settings[name];
  globalThis.fetch = fetcher;
  try {
    await run();
  } finally {
    Deno.env.get = originalGet;
    globalThis.fetch = originalFetch;
  }
}

Deno.test("OAuth start authenticates the supplied JWT and returns the complete signed consent URL", async () => {
  await mocked(async (input, init) => {
    assertEquals(String(input), "https://project.example.test/auth/v1/user");
    assertEquals(new Headers(init?.headers).get("Authorization"), "Bearer test-user-jwt");
    return Response.json({ id: userId });
  }, async () => {
    const response = await start(
      new Request("https://example.test/start", {
        method: "POST",
        headers: { Authorization: "Bearer test-user-jwt" },
      }),
    );
    assertEquals(response.status, 200);
    const url = new URL((await response.json()).url);
    assertEquals(url.origin + url.pathname, "https://accounts.google.com/o/oauth2/v2/auth");
    for (
      const [key, expected] of Object.entries({
        client_id: "test-client",
        response_type: "code",
        access_type: "offline",
        prompt: "consent",
        include_granted_scopes: "true",
        redirect_uri: "https://project.example.test/functions/v1/health-oauth-callback",
        scope: GOOGLE_SCOPES.join(" "),
      })
    ) assertEquals(url.searchParams.get(key), expected);
    const state = await verifyState(url.searchParams.get("state")!, settings.OAUTH_STATE_SECRET);
    assertEquals(state.userId, userId);
    assert(state.expiresAt <= Math.floor(Date.now() / 1000) + 600);
    assertEquals(
      (await start(new Request("https://example.test/start", { method: "POST" }))).status,
      401,
    );
    assertEquals(
      (await start(new Request("https://example.test/start", { method: "OPTIONS" }))).status,
      204,
    );
    assertEquals((await start(new Request("https://example.test/start"))).status, 405);
  });
});

Deno.test("OAuth callback stores the refresh token, enqueues 35 days and redirects without tokens", async () => {
  const calls: string[] = [];
  await mocked(async (input, init) => {
    const url = String(input);
    calls.push(url);
    if (url === "https://oauth2.googleapis.com/token") {
      return Response.json({
        access_token: "test-access",
        refresh_token: "test-refresh",
        expires_in: 3600,
        scope: "scope-one",
      });
    }
    if (url.endsWith("/identity")) return Response.json({ healthUserId: "health-user-1" });
    const body = JSON.parse(String(init?.body));
    if (url.endsWith("/store_health_connection")) {
      assertEquals(body, {
        p_user_id: userId,
        p_health_user_id: "health-user-1",
        p_refresh_token: "test-refresh",
        p_scopes: ["scope-one"],
      });
    } else assertEquals(body, { p_user_id: userId, p_days: 35 });
    return new Response(null, { status: 204 });
  }, async () => {
    const state = await signState({ userId, ttlSeconds: 600 }, settings.OAUTH_STATE_SECRET);
    const response = await callback(
      new Request(`https://example.test/callback?code=test-code&state=${state}`),
    );
    assertEquals(response.status, 302);
    assertEquals(response.headers.get("Location"), "wearablecompanion://connected?status=ok");
    assertEquals(calls.map((url) => new URL(url).pathname), [
      "/token",
      "/v4/users/me/identity",
      "/rest/v1/rpc/store_health_connection",
      "/rest/v1/rpc/enqueue_backfill",
    ]);
  });
});

Deno.test("OAuth callback uses only fixed short reason codes for every failure stage", async () => {
  const state = await signState({ userId, ttlSeconds: 600 }, settings.OAUTH_STATE_SECRET);
  for (
    const stage of [
      "bad_state",
      "denied",
      "no_refresh_token",
      "exchange_failed",
      "identity_failed",
      "store_failed",
      "enqueue_failed",
    ]
  ) {
    await mocked(async (input) => {
      const url = String(input);
      if (
        (stage === "exchange_failed" && url.endsWith("/token")) ||
        (stage === "identity_failed" && url.endsWith("/identity")) ||
        (stage === "store_failed" && url.endsWith("/store_health_connection")) ||
        (stage === "enqueue_failed" && url.endsWith("/enqueue_backfill"))
      ) {
        return Response.json({ error: "raw provider text with test credentials" }, { status: 503 });
      }
      if (url.endsWith("/token")) {
        return Response.json({
          access_token: "test-access",
          expires_in: 3600,
          ...(stage === "no_refresh_token" ? {} : { refresh_token: "test-refresh" }),
        });
      }
      if (url.endsWith("/identity")) return Response.json({ healthUserId: "health-user-1" });
      return new Response(null, { status: 204 });
    }, async () => {
      const query = new URLSearchParams({
        state: stage === "bad_state" ? "tampered" : state,
        code: "test-code",
      });
      if (stage === "denied") query.set("error", "access_denied");
      const response = await callback(new Request(`https://example.test/callback?${query}`));
      assertEquals(
        response.headers.get("Location"),
        `wearablecompanion://connected?status=error&reason=${
          stage === "enqueue_failed" ? "store_failed" : stage
        }`,
      );
    });
  }
});

Deno.test("worker accepts verified users or the exact service key and rejects unverified JWTs", async () => {
  const authenticated: string[] = [];
  await mocked(async (input, init) => {
    const url = String(input);
    if (url.endsWith("/auth/v1/user")) {
      const auth = new Headers(init?.headers).get("Authorization")!;
      authenticated.push(auth);
      return auth === "Bearer test-user-jwt"
        ? Response.json({ id: userId })
        : Response.json({ message: "invalid JWT" }, { status: 401 });
    }
    if (url.endsWith("/claim_sync_jobs")) return Response.json([]);
    return new Response(null, { headers: { "Content-Range": "*/0" } });
  }, async () => {
    for (const token of ["test-user-jwt", "test-service-key"]) {
      const response = await sync(
        new Request("https://example.test/sync", {
          method: "POST",
          headers: { Authorization: `Bearer ${token}` },
        }),
      );
      assertEquals(response.status, 200);
      assertEquals(await response.json(), { processed: 0, failed: 0, remaining: 0 });
    }
    assertEquals(
      (await sync(
        new Request("https://example.test/sync", {
          method: "POST",
          headers: { Authorization: "Bearer forged-jwt" },
        }),
      )).status,
      401,
    );
    assertEquals(authenticated, ["Bearer test-user-jwt", "Bearer forged-jwt"]);
  });
});
