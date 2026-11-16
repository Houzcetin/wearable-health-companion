import { createClient } from "npm:@supabase/supabase-js@2";
import { handler } from "./handler.ts";
import { assert, assertEquals } from "../_shared/test_helpers.ts";
import { HttpError } from "../_shared/supabase.ts";

const userId = "00000000-0000-4000-8000-000000000001";
function request() {
  return new Request("https://example.test/export", { method: "POST" });
}
Deno.test("export projects identity and connection fields, scopes every table and paginates records", async () => {
  const queries: URL[] = [];
  const connection = {
    status: "active",
    connected_at: "2026-11-01",
    last_synced_at: "2026-11-13",
    scopes: ["scope"],
    refresh_token_secret_id: "private-vault-id",
    health_user_id: "private-health-id",
    token: "private-token",
  };
  const db = createClient("https://example.test", "test-key", {
    auth: { persistSession: false, autoRefreshToken: false },
    global: {
      fetch: (input) => {
        const url = new URL(String(input));
        queries.push(url);
        const table = url.pathname.split("/").at(-1);
        if (url.pathname.includes("/auth/")) {
          return Promise.resolve(
            Response.json({
              id: userId,
              email: "user@example.test",
              app_metadata: { private: "hidden" },
            }),
          );
        }
        if (table === "health_connections") return Promise.resolve(Response.json(connection));
        if (table === "profiles") {
          return Promise.resolve(Response.json({ user_id: userId, timezone: "UTC" }));
        }
        if (table === "daily_metrics" || table === "workouts") {
          const offset = Number(url.searchParams.get("offset"));
          const key = table === "workouts" ? "started_at" : "date";
          return Promise.resolve(Response.json(
            offset === 0
              ? Array.from({ length: 1000 }, (_, i) => ({ [key]: String(i) }))
              : [{ [key]: "last" }],
          ));
        }
        return Promise.resolve(Response.json([{ id: 1 }]));
      },
    },
  });
  const response = await handler(request(), {
    db,
    userId: () => Promise.resolve(userId),
    now: () => 0,
  });
  assertEquals(response.status, 200);
  const body = await response.json();
  assertEquals(body.exported_at, "1970-01-01T00:00:00.000Z");
  assertEquals(body.user, { id: userId, email: "user@example.test" });
  assertEquals(body.health_connection, {
    status: "active",
    connected_at: "2026-11-01",
    last_synced_at: "2026-11-13",
    scopes: ["scope"],
  });
  assertEquals(body.daily_metrics.length, 1001);
  assertEquals(body.workouts.length, 1001);
  assertEquals(body.workouts.at(-1), { started_at: "last" });
  for (const value of ["private-vault-id", "private-health-id", "private-token", "app_metadata"]) {
    assert(!JSON.stringify(body).includes(value));
  }
  for (const url of queries.filter((url) => url.pathname.includes("/rest/"))) {
    assertEquals(url.searchParams.get("user_id"), "eq." + userId);
  }
  assertEquals(
    queries.find((url) => url.pathname.endsWith("daily_metrics"))?.searchParams.get("order"),
    "date.asc",
  );
  assertEquals(
    queries.find((url) => url.pathname.endsWith("coach_messages"))?.searchParams.get("order"),
    "id.asc",
  );
  assertEquals(
    queries.find((url) => url.pathname.endsWith("workouts"))?.searchParams.get("order"),
    "started_at.asc",
  );
});

Deno.test("export returns null for an absent connection and requires a session", async () => {
  const db = createClient("https://example.test", "test-key", {
    auth: { persistSession: false, autoRefreshToken: false },
    global: {
      fetch: (input) =>
        Promise.resolve(Response.json(String(input).includes("/auth/") ? { id: userId } : [])),
    },
  });
  const response = await handler(request(), { db, userId: () => Promise.resolve(userId) });
  assertEquals(response.status, 200);
  const body = await response.json();
  assertEquals(body.health_connection, null);
  assertEquals(body.workouts, []);
  assertEquals(
    (await handler(request(), { userId: () => Promise.reject(new HttpError(401, "unauthorized")) }))
      .status,
    401,
  );
});
