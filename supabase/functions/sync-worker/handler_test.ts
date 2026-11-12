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
  globalThis.fetch = (input) => {
    if (String(input).endsWith("/claim_sync_jobs")) {
      claims++;
      return Promise.resolve(Response.json([]));
    }
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
