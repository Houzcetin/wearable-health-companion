import { handler } from "./handler.ts";
import { assertEquals } from "../_shared/test_helpers.ts";

Deno.test("worker accepts a cron secret for one pass and rejects wrong, empty or unset secrets", async () => {
  const originalGet = Deno.env.get;
  const originalFetch = globalThis.fetch;
  let cron: string | undefined = "synthetic-cron-secret";
  let claims = 0;
  const settings: Record<string, string> = {
    SUPABASE_URL: "https://example.test",
    SUPABASE_SERVICE_ROLE_KEY: "synthetic-service-key",
    GOOGLE_OAUTH_CLIENT_ID: "client",
    GOOGLE_OAUTH_CLIENT_SECRET: "secret",
  };
  Deno.env.get = (name) => name === "SYNC_CRON_SECRET" ? cron : settings[name];
  globalThis.fetch = (input, init) => {
    assertEquals(new Headers(init?.headers).get("Authorization"), "Bearer synthetic-service-key");
    if (String(input).endsWith("/claim_sync_jobs")) {
      assertEquals(JSON.parse(String(init?.body)), { batch_size: 25 });
      claims++;
      return Promise.resolve(Response.json([]));
    }
    const url = new URL(String(input));
    assertEquals(url.pathname, "/rest/v1/sync_queue");
    assertEquals(url.searchParams.get("user_id"), null);
    return Promise.resolve(new Response(null, { headers: { "Content-Range": "*/12" } }));
  };
  const request = (value: string) =>
    new Request("https://example.test/sync", {
      method: "POST",
      headers: { "x-cron-secret": value },
    });
  try {
    const response = await handler(request(cron));
    assertEquals(response.status, 200);
    assertEquals(await response.json(), { processed: 0, failed: 0, remaining: 12 });
    assertEquals(claims, 1);
    assertEquals((await handler(request("wrong"))).status, 401);
    cron = "";
    assertEquals((await handler(request(""))).status, 401);
    cron = undefined;
    assertEquals((await handler(request(""))).status, 401);
    assertEquals(claims, 1);
  } finally {
    Deno.env.get = originalGet;
    globalThis.fetch = originalFetch;
  }
});

Deno.test("worker rate limits each verified user before claiming, without limiting the service key", async () => {
  const originalGet = Deno.env.get;
  const originalFetch = globalThis.fetch;
  const settings: Record<string, string> = {
    SUPABASE_URL: "https://example.test",
    SUPABASE_ANON_KEY: "synthetic-anon-key",
    SUPABASE_SERVICE_ROLE_KEY: "synthetic-service-key",
    GOOGLE_OAUTH_CLIENT_ID: "client",
    GOOGLE_OAUTH_CLIENT_SECRET: "secret",
  };
  const lastCalls = new Map<string, number>();
  const claims: unknown[] = [];
  let now = 0;
  let failRateCheck = false;
  Deno.env.get = (name) => settings[name];
  globalThis.fetch = (input, init) => {
    const url = new URL(String(input));
    const token = new Headers(init?.headers).get("Authorization");
    if (url.pathname === "/auth/v1/user") {
      return Promise.resolve(Response.json({
        id: token === "Bearer user-a-jwt"
          ? "00000000-0000-4000-8000-000000000001"
          : "00000000-0000-4000-8000-000000000002",
      }));
    }
    assertEquals(token, "Bearer synthetic-service-key");
    if (url.pathname.endsWith("/try_start_user_sync")) {
      if (failRateCheck) {
        return Promise.resolve(Response.json({ code: "XX000" }, { status: 500 }));
      }
      const userId = JSON.parse(String(init?.body)).p_user_id;
      const previous = lastCalls.get(userId);
      const allowed = previous === undefined || now - previous >= 60000;
      if (allowed) lastCalls.set(userId, now);
      return Promise.resolve(Response.json(allowed));
    }
    if (url.pathname.endsWith("/claim_sync_jobs")) {
      claims.push(JSON.parse(String(init?.body)));
      return Promise.resolve(Response.json([]));
    }
    assertEquals(url.pathname, "/rest/v1/sync_queue");
    return Promise.resolve(new Response(null, { headers: { "Content-Range": "*/0" } }));
  };
  const request = (token: string) =>
    new Request("https://example.test/sync", {
      method: "POST",
      headers: { Authorization: `Bearer ${token}` },
    });
  try {
    assertEquals((await handler(request("user-a-jwt"))).status, 200);
    const limited = await handler(request("user-a-jwt"));
    assertEquals(limited.status, 429);
    assertEquals(await limited.json(), { error: "sync_rate_limited" });
    assertEquals(claims.length, 1);
    assertEquals((await handler(request("user-b-jwt"))).status, 200);
    now = 59999;
    assertEquals((await handler(request("user-a-jwt"))).status, 429);
    assertEquals(claims.length, 2);
    now = 60000;
    assertEquals((await handler(request("user-a-jwt"))).status, 200);
    assertEquals((await handler(request("synthetic-service-key"))).status, 200);
    assertEquals((await handler(request("synthetic-service-key"))).status, 200);
    assertEquals(claims, [
      { batch_size: 25, p_user_id: "00000000-0000-4000-8000-000000000001" },
      { batch_size: 25, p_user_id: "00000000-0000-4000-8000-000000000002" },
      { batch_size: 25, p_user_id: "00000000-0000-4000-8000-000000000001" },
      { batch_size: 25 },
      { batch_size: 25 },
    ]);
    failRateCheck = true;
    const failed = await handler(request("user-a-jwt"));
    assertEquals(failed.status, 500);
    assertEquals(await failed.json(), { error: "internal_error" });
    assertEquals(claims.length, 5);
  } finally {
    Deno.env.get = originalGet;
    globalThis.fetch = originalFetch;
  }
});
