import { createClient } from "npm:@supabase/supabase-js@2";
import { handler } from "./handler.ts";
import { assertEquals } from "../_shared/test_helpers.ts";
import { HttpError } from "../_shared/supabase.ts";

const userId = "00000000-0000-4000-8000-000000000001";
function request(scope: unknown) {
  return new Request("https://example.test/delete", {
    method: "POST",
    body: JSON.stringify({ scope }),
  });
}
function database(token: string | null = "synthetic-refresh-token", failDelete = false) {
  const calls: { path: string; method: string; body: unknown; user: string | null }[] = [];
  const db = createClient("https://example.test", "test-key", {
    auth: { persistSession: false, autoRefreshToken: false },
    global: {
      fetch: (input, init) => {
        const url = new URL(String(input));
        calls.push({
          path: url.pathname,
          method: init?.method ?? "GET",
          body: init?.body ? JSON.parse(String(init.body)) : null,
          user: url.searchParams.get("user_id"),
        });
        if (url.pathname.endsWith("get_health_refresh_token")) {
          return Promise.resolve(Response.json(token));
        }
        if (url.pathname.endsWith("delete_user_health_data") && failDelete) {
          return Promise.resolve(Response.json({ message: "private detail" }, { status: 500 }));
        }
        if (url.pathname.includes("/auth/")) return Promise.resolve(Response.json({ id: userId }));
        return Promise.resolve(new Response(null, { status: 204 }));
      },
    },
  });
  return { db, calls };
}

Deno.test("health deletion revokes first, deletes data and records consent withdrawal after failed revoke", async () => {
  const store = database();
  const fetcher: typeof fetch = (url, init) => {
    assertEquals(String(url), "https://oauth2.googleapis.com/revoke");
    assertEquals(init?.method, "POST");
    assertEquals(
      new Headers(init?.headers).get("Content-Type"),
      "application/x-www-form-urlencoded",
    );
    assertEquals(new URLSearchParams(String(init?.body)).get("token"), "synthetic-refresh-token");
    assertEquals(store.calls.length, 1);
    return Promise.resolve(new Response(null, { status: 503 }));
  };
  const response = await handler(request("health"), {
    ...store,
    fetcher,
    userId: () => Promise.resolve(userId),
  });
  assertEquals(response.status, 200);
  assertEquals(await response.json(), { deleted: "health" });
  assertEquals(store.calls.map((call) => call.path), [
    "/rest/v1/rpc/get_health_refresh_token",
    "/rest/v1/rpc/delete_user_health_data",
    "/rest/v1/consent_events",
  ]);
  assertEquals(store.calls[1].body, { p_user_id: userId });
  assertEquals(store.calls[2].body, { user_id: userId, kind: "health_data", granted: false });
});

Deno.test("account deletion removes consent before auth user and skips revoke without a token", async () => {
  const store = database(null);
  const response = await handler(request("account"), {
    ...store,
    userId: () => Promise.resolve(userId),
    fetcher: () => Promise.reject(new Error("must not revoke")),
  });
  assertEquals(response.status, 200);
  assertEquals(await response.json(), { deleted: "account" });
  // supabase-js may look the user up (GET) before deleting; only writes are ordered here.
  assertEquals(
    store.calls.filter((call) => call.method !== "GET").map((call) => [call.path, call.method]),
    [
      ["/rest/v1/rpc/get_health_refresh_token", "POST"],
      ["/rest/v1/rpc/delete_user_health_data", "POST"],
      ["/rest/v1/consent_events", "DELETE"],
      ["/auth/v1/admin/users/" + userId, "DELETE"],
    ],
  );
  assertEquals(store.calls[2].user, "eq." + userId);
});

Deno.test("transport revoke failures still delete, while database failures stop account deletion", async () => {
  const store = database();
  assertEquals(
    (await handler(request("health"), {
      ...store,
      userId: () => Promise.resolve(userId),
      fetcher: () => Promise.reject(new Error("sensitive transport detail")),
    })).status,
    200,
  );
  const failed = database(null, true);
  const response = await handler(request("account"), {
    ...failed,
    userId: () => Promise.resolve(userId),
  });
  assertEquals(response.status, 500);
  assertEquals(await response.json(), { error: "delete_failed" });
  assertEquals(failed.calls.length, 2);
});

Deno.test("deletion validates scope and authenticates before doing work", async () => {
  const store = database();
  assertEquals(
    (await handler(request("everything"), { ...store, userId: () => Promise.resolve(userId) }))
      .status,
    400,
  );
  assertEquals(
    (await handler(request("account"), {
      ...store,
      userId: () => Promise.reject(new HttpError(401, "unauthorized")),
    })).status,
    401,
  );
  assertEquals(store.calls.length, 0);
});
