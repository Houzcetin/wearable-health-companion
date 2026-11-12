// deno-lint-ignore-file require-await
// Transport doubles implement async interfaces without performing I/O.
import { createClient } from "npm:@supabase/supabase-js@2";
import { createQueueStore } from "./queue.ts";
import { assert, assertEquals } from "./test_helpers.ts";

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
