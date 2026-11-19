// deno-lint-ignore-file require-await
// Transport doubles implement async interfaces without performing I/O.
import { createClient } from "npm:@supabase/supabase-js@2";
import { createQueueStore, QueueError } from "./queue.ts";
import { runWorker } from "./worker.ts";
import { assert, assertEquals, assertRejects } from "./test_helpers.ts";

Deno.test("queue claims and remaining counts keep their user scope across batches", async () => {
  const claims: unknown[] = [];
  const scopes: (string | null)[] = [];
  const client = createClient("https://example.test", "test-key", {
    auth: { persistSession: false, autoRefreshToken: false },
    global: {
      fetch: async (input, init) => {
        const url = new URL(String(input));
        if (url.pathname.endsWith("/claim_sync_jobs")) {
          claims.push(JSON.parse(String(init?.body)));
          return Response.json([]);
        }
        assertEquals(url.pathname, "/rest/v1/sync_queue");
        scopes.push(url.searchParams.get("user_id"));
        return new Response(null, { headers: { "Content-Range": "*/3" } });
      },
    },
  });
  const scoped = createQueueStore(client, "user-1");
  await scoped.claim(25);
  await scoped.claim(10);
  assertEquals(await scoped.remaining(), 3);
  const global = createQueueStore(client);
  await global.claim(25);
  assertEquals(await global.remaining(), 3);
  assertEquals(claims, [
    { batch_size: 25, p_user_id: "user-1" },
    { batch_size: 10, p_user_id: "user-1" },
    { batch_size: 25 },
  ]);
  assertEquals(scopes, ["eq.user-1", null]);
});

Deno.test("user context requires health consent before reading a connection or Vault token", async () => {
  for (const profile of [null, { timezone: "UTC", health_consent_at: null }]) {
    const requests: URL[] = [];
    const client = createClient("https://example.test", "test-key", {
      auth: { persistSession: false, autoRefreshToken: false },
      global: {
        fetch: async (input) => {
          requests.push(new URL(String(input)));
          return Response.json(profile);
        },
      },
    });
    try {
      await createQueueStore(client).userContext("user-1");
      throw new Error("Expected consent rejection");
    } catch (error) {
      assert(error instanceof QueueError);
      assertEquals(error.code, "health_consent_required");
      assertEquals(error.transient, false);
    }
    assertEquals(requests.length, 1);
    assertEquals(requests[0].pathname, "/rest/v1/profiles");
    assertEquals(requests[0].searchParams.get("select"), "timezone,health_consent_at");
  }
});

Deno.test("worker fails unconsented jobs without token, provider, or metric access", async () => {
  let claimed = false;
  const requests: { url: URL; body: unknown }[] = [];
  const client = createClient("https://example.test", "test-key", {
    auth: { persistSession: false, autoRefreshToken: false },
    global: {
      fetch: async (input, init) => {
        const url = new URL(String(input));
        requests.push({ url, body: init?.body ? JSON.parse(String(init.body)) : null });
        if (url.pathname.endsWith("/claim_sync_jobs")) {
          const jobs = claimed ? [] : [{
            id: 1,
            user_id: "user-1",
            data_type: "steps",
            date: "2026-11-19",
            attempts: 1,
          }];
          claimed = true;
          return Response.json(jobs);
        }
        if (url.pathname.endsWith("/profiles")) {
          return Response.json({ timezone: "UTC", health_consent_at: null });
        }
        assertEquals(url.pathname, "/rest/v1/sync_queue");
        return new Response(null, { status: 204, headers: { "Content-Range": "*/0" } });
      },
    },
  });
  const result = await runWorker({
    store: createQueueStore(client),
    healthForUser: () => {
      throw new Error("Must not refresh or access Google Health");
    },
  });
  assertEquals(result, { processed: 1, failed: 1, remaining: 0 });
  assert(
    requests.some((request) =>
      JSON.stringify(request.body) ===
        JSON.stringify({ status: "failed", last_error: "health_consent_required" })
    ),
  );
});

Deno.test("user context still loads active consented connections and checks database failures", async () => {
  let profileFails = false;
  const client = createClient("https://example.test", "test-key", {
    auth: { persistSession: false, autoRefreshToken: false },
    global: {
      fetch: async (input) => {
        const url = new URL(String(input));
        if (url.pathname.endsWith("/profiles")) {
          return profileFails ? Response.json({ code: "XX000" }, { status: 500 }) : Response.json({
            timezone: "Europe/Istanbul",
            health_consent_at: "2026-11-19T00:00:00Z",
          });
        }
        if (url.pathname.endsWith("/health_connections")) {
          return Response.json({ status: "active", health_user_id: "health-1", scopes: ["sleep"] });
        }
        assertEquals(url.pathname, "/rest/v1/rpc/get_health_refresh_token");
        return Response.json("synthetic-token");
      },
    },
  });
  assertEquals(await createQueueStore(client).userContext("user-1"), {
    timeZone: "Europe/Istanbul",
    refreshToken: "synthetic-token",
    healthUserId: "health-1",
    scopes: ["sleep"],
  });
  profileFails = true;
  await assertRejects(() => createQueueStore(client).userContext("user-1"), "database_error");
});

Deno.test("PostgREST upsert supplies only the mapped columns, provenance, demo flag and key", async () => {
  const calls: { url: URL; body: unknown; method?: string; headers: Headers }[] = [];
  const client = createClient("https://example.test", "test-key", {
    auth: { persistSession: false, autoRefreshToken: false },
    global: {
      fetch: async (input, init) => {
        calls.push({
          url: new URL(String(input)),
          body: JSON.parse(String(init?.body)),
          method: init?.method,
          headers: new Headers(init?.headers),
        });
        return new Response(null, { status: 201 });
      },
    },
  });
  const store = createQueueStore(client);
  await store.upsert("user-1", "2026-11-11", { steps: 0, hrv_ms: 47.3 });
  assertEquals(calls.length, 1);
  const body = calls[0].body as Record<string, unknown>;
  assertEquals(Object.keys(body).sort(), [
    "date",
    "hrv_ms",
    "is_demo",
    "source_updated_at",
    "steps",
    "user_id",
  ]);
  assertEquals(body.is_demo, false);
  assertEquals(body.steps, 0);
  assertEquals(calls[0].url.searchParams.get("on_conflict"), "user_id,date");
  assert(calls[0].headers.get("Prefer")?.includes("resolution=merge-duplicates"));
  assert(calls[0].headers.get("Prefer")?.includes("missing=default"));
  await store.upsert("user-1", "2026-11-11", {});
  assertEquals(calls.length, 1);
});

Deno.test("a retry collision retains the newer pending job and settles the running duplicate", async () => {
  const calls: { url: URL; method?: string; body: Record<string, unknown> }[] = [];
  const client = createClient("https://example.test", "test-key", {
    auth: { persistSession: false, autoRefreshToken: false },
    global: {
      fetch: async (input, init) => {
        const request = {
          url: new URL(String(input)),
          method: init?.method,
          body: init?.body ? JSON.parse(String(init.body)) as Record<string, unknown> : {},
        };
        calls.push(request);
        if (calls.length === 1) {
          return Response.json({ code: "23505", message: "duplicate" }, { status: 409 });
        }
        if (init?.method === "GET") return Response.json({ id: 2 });
        return new Response(null, { status: 204 });
      },
    },
  });
  const store = createQueueStore(client);
  await store.retry(
    { id: 1, user_id: "user-1", data_type: "steps", date: "2026-11-11", attempts: 1 },
    "google_http_503",
    "2026-11-11T10:00:00Z",
  );
  assertEquals(calls.map((call) => call.method), ["PATCH", "GET", "PATCH"]);
  assertEquals(calls[1].url.searchParams.get("status"), "eq.pending");
  assertEquals(calls[2].body, { status: "done", last_error: "superseded_by_pending" });
});

Deno.test("revocation fails all pending and running jobs only for the revoked user", async () => {
  const calls: { url: URL; body: Record<string, unknown> }[] = [];
  const client = createClient("https://example.test", "test-key", {
    auth: { persistSession: false, autoRefreshToken: false },
    global: {
      fetch: async (input, init) => {
        calls.push({ url: new URL(String(input)), body: JSON.parse(String(init?.body)) });
        return new Response(null, { status: 204 });
      },
    },
  });
  await createQueueStore(client).revoke("user-1");
  assertEquals(calls[0].body, { status: "revoked", last_error: "invalid_grant" });
  assertEquals(calls[1].body, { status: "failed", last_error: "invalid_grant" });
  assertEquals(calls[1].url.searchParams.get("status"), "in.(pending,running)");
  assertEquals(calls[1].url.searchParams.get("user_id"), "eq.user-1");
});
