import { createHandler } from "./handler.ts";
import { assertEquals } from "../_shared/test_helpers.ts";
import { signatureFixture } from "../_shared/webhook_test_helpers.ts";

const secret = "synthetic-webhook-secret";
function notification(type = "steps", start = "2026-11-10", end = "2026-11-12") {
  return {
    data: {
      version: "1",
      healthUserId: "health-user-1",
      operation: "UPSERT",
      dataType: type,
      intervals: [{
        civilIso8601TimeInterval: { startTime: start + "T23:00:00", endTime: end + "T07:00:00" },
      }],
    },
  };
}
function request(
  body: string,
  signature?: string,
  authorization: string | null = "Bearer " + secret,
) {
  return new Request("https://example.test/webhook", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "User-Agent": "Google-Health-API-Webhooks",
      ...(authorization === null ? {} : { Authorization: authorization }),
      ...(signature ? { "GOOGLE-HEALTH-API-SIGNATURE": signature } : {}),
    },
    body,
  });
}

Deno.test("webhook verification requires the exact secret and configured authorization", async () => {
  const handle = createHandler({ secret: () => secret });
  assertEquals((await handle(request('{"type":"verification"}'))).status, 200);
  assertEquals((await handle(request('{"type":"verification"}', undefined, null))).status, 401);
  assertEquals(
    (await handle(request('{"type":"verification"}', undefined, "bearer " + secret))).status,
    401,
  );
  const missing = createHandler({ secret: () => "" });
  assertEquals((await missing(request('{"type":"verification"}'))).status, 500);
});

Deno.test("webhook rejects bad signatures and enqueues signed date ranges before replying", async () => {
  const fixture = await signatureFixture();
  const calls: unknown[] = [];
  const handle = createHandler({
    secret: () => secret,
    fetcher: () => Promise.resolve(Response.json(fixture.keyset)),
    rpc: (name, args) => {
      calls.push({ name, ...args });
      return Promise.resolve({ error: null });
    },
  });
  const body = JSON.stringify(notification());
  assertEquals((await handle(request(body, "invalid"))).status, 401);
  assertEquals(calls.length, 0);
  const signature = await fixture.sign(new TextEncoder().encode(body));
  const response = await handle(request(body, signature));
  assertEquals(response.status, 204);
  assertEquals(await response.text(), "");
  assertEquals(calls, [{
    name: "enqueue_webhook_job",
    p_health_user_id: "health-user-1",
    p_data_type: "steps",
    p_dates: ["2026-11-10", "2026-11-11", "2026-11-12"],
  }]);
});

Deno.test("webhook groups batches, ignores unknown types and duplicate delivery is harmless", async () => {
  const fixture = await signatureFixture();
  const pending = new Set<string>();
  const calls: { p_data_type: string; p_dates: string[] }[] = [];
  const handle = createHandler({
    secret: () => secret,
    fetcher: () => Promise.resolve(Response.json(fixture.keyset)),
    rpc: (_name, args) => {
      calls.push(args);
      for (const date of args.p_dates) {
        pending.add(JSON.stringify([args.p_health_user_id, args.p_data_type, date]));
      }
      return Promise.resolve({ error: null });
    },
  });
  const deleted = notification("sleep", "2026-11-11", "2026-11-12");
  deleted.data.operation = "DELETE";
  const body = JSON.stringify([
    notification(),
    notification("steps", "2026-11-12", "2026-11-13"),
    deleted,
    notification("unknown"),
  ]);
  const signature = await fixture.sign(new TextEncoder().encode(body));
  assertEquals((await handle(request(body, signature))).status, 204);
  assertEquals((await handle(request(body, signature))).status, 204);
  assertEquals(pending.size, 6);
  assertEquals(calls.map((args) => args.p_data_type), ["steps", "sleep", "steps", "sleep"]);
  assertEquals(calls[0].p_dates, ["2026-11-10", "2026-11-11", "2026-11-12", "2026-11-13"]);
  assertEquals(calls[1].p_dates, ["2026-11-11", "2026-11-12"]);
});

Deno.test("webhook caps dates at 14, preserves wake date and acknowledges signed malformed JSON", async () => {
  const fixture = await signatureFixture();
  const dates: string[][] = [];
  const handle = createHandler({
    secret: () => secret,
    fetcher: () => Promise.resolve(Response.json(fixture.keyset)),
    rpc: (_name, args) => {
      dates.push(args.p_dates);
      return Promise.resolve({ error: null });
    },
  });
  for (const body of [JSON.stringify(notification("sleep", "2026-10-01", "2026-11-12")), "{bad"]) {
    const signature = await fixture.sign(new TextEncoder().encode(body));
    assertEquals((await handle(request(body, signature))).status, 204);
  }
  assertEquals(dates.length, 1);
  assertEquals(dates[0].length, 14);
  assertEquals(dates[0].includes("2026-11-12"), true);
});

Deno.test("webhook enqueue failures remain retryable", async () => {
  const fixture = await signatureFixture();
  const handle = createHandler({
    secret: () => secret,
    fetcher: () => Promise.resolve(Response.json(fixture.keyset)),
    rpc: () => Promise.resolve({ error: { message: "sensitive database detail" } }),
  });
  const body = JSON.stringify(notification());
  const response = await handle(request(body, await fixture.sign(new TextEncoder().encode(body))));
  assertEquals(response.status, 500);
  assertEquals(await response.json(), { error: "webhook_enqueue_failed" });
});
