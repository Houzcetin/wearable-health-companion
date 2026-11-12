// deno-lint-ignore-file require-await
// Transport doubles implement async interfaces without performing I/O.
import { exchangeCode, GoogleError, GoogleHealthClient, refreshAccessToken } from "./google.ts";
import { assert, assertEquals, assertRejects } from "./test_helpers.ts";

const config = {
  clientId: "test-client",
  clientSecret: "test-secret",
  redirectUri: "https://example.test/callback",
};

Deno.test("OAuth uses form POSTs and distinguishes revoked grants from transient failures", async () => {
  const bodies: URLSearchParams[] = [];
  const fetcher: typeof fetch = async (url, init) => {
    assertEquals(String(url), "https://oauth2.googleapis.com/token");
    assertEquals(init?.method, "POST");
    bodies.push(new URLSearchParams(String(init?.body)));
    return Response.json({
      access_token: "test-access",
      refresh_token: "test-refresh",
      expires_in: 3600,
      scope: "scope-one scope-two",
    });
  };
  const token = await exchangeCode("test-code", config, fetcher);
  assertEquals(token.scopes, ["scope-one", "scope-two"]);
  assertEquals(bodies[0].get("grant_type"), "authorization_code");
  assertEquals(bodies[0].get("redirect_uri"), config.redirectUri);
  await refreshAccessToken("test-refresh", config, fetcher);
  assertEquals(bodies[1].get("grant_type"), "refresh_token");
  assertEquals(bodies[1].get("refresh_token"), "test-refresh");
  for (
    const [status, body, code, transient] of [
      [
        400,
        { error: "invalid_grant", error_description: "never expose this test token" },
        "invalid_grant",
        false,
      ],
      [429, {}, "google_http_429", true],
      [503, {}, "google_http_503", true],
      [403, {}, "google_http_403", false],
    ] as const
  ) {
    try {
      await refreshAccessToken("test-refresh", config, async () => Response.json(body, { status }));
      throw new Error("Expected provider error");
    } catch (error) {
      assert(error instanceof GoogleError);
      assertEquals(error.code, code);
      assertEquals(error.transient, transient);
      assert(!error.message.includes("test token"));
    }
  }
});

Deno.test("Google Health uses the documented identity and nested daily rollup request", async () => {
  const calls: { url: string; init?: RequestInit }[] = [];
  const client = new GoogleHealthClient("test-access", async (url, init) => {
    calls.push({ url: String(url), init });
    return Response.json(String(url).endsWith("identity") ? { healthUserId: "health-user-1" } : {});
  });
  assertEquals(await client.getIdentity(), "health-user-1");
  await client.dailyRollUp("steps", "2026-11-11");
  assertEquals(calls[0].url, "https://health.googleapis.com/v4/users/me/identity");
  const unlinked = new GoogleHealthClient("test-access", async () =>
    Response.json(
      {
        error: {
          code: 400,
          status: "FAILED_PRECONDITION",
          message: "The account is not linked to Google Health.",
        },
      },
      { status: 400 },
    ));
  try {
    await unlinked.getIdentity();
    throw new Error("Expected not linked");
  } catch (error) {
    assert(error instanceof GoogleError);
    assertEquals(error.code, "google_not_linked");
    assertEquals(error.transient, false);
  }
  assertEquals(
    calls[1].url,
    "https://health.googleapis.com/v4/users/me/dataTypes/steps/dataPoints:dailyRollUp",
  );
  assertEquals(JSON.parse(String(calls[1].init?.body)), {
    range: {
      start: { date: { year: 2026, month: 11, day: 11 } },
      end: { date: { year: 2026, month: 11, day: 12 } },
    },
    windowSizeDays: 1,
  });
  await assertRejects(
    () => client.dailyRollUp("daily-resting-heart-rate", "2026-11-11"),
    "unsupported_rollup",
  );
});

Deno.test("sleep requests filter physical wake instants in the profile timezone and collect every page", async () => {
  const urls: URL[] = [];
  const client = new GoogleHealthClient("test-access", async (input) => {
    const url = new URL(String(input));
    urls.push(url);
    return Response.json(
      url.searchParams.has("pageToken")
        ? { dataPoints: [{ name: "second" }] }
        : { dataPoints: [{ name: "first" }], nextPageToken: "next page" },
    );
  });
  const result = await client.listDataPoints("sleep", {
    startDate: "2026-11-11",
    endDate: "2026-11-12",
    timeZone: "Europe/Istanbul",
  });
  assertEquals(
    urls[0].searchParams.get("filter"),
    'sleep.interval.end_time >= "2026-11-10T21:00:00.000Z" AND sleep.interval.end_time < "2026-11-11T21:00:00.000Z"',
  );
  assertEquals(urls[1].searchParams.get("pageToken"), "next page");
  assertEquals(result.dataPoints, [{ name: "first" }, { name: "second" }]);
});

Deno.test("list requests use the type-specific documented filters", async () => {
  const filters: string[] = [];
  const client = new GoogleHealthClient("test-access", async (input) => {
    filters.push(new URL(String(input)).searchParams.get("filter") ?? "");
    return Response.json({});
  });
  const range = { startDate: "2026-11-11", endDate: "2026-11-12", timeZone: "UTC" };
  await client.listDataPoints("daily-resting-heart-rate", range);
  await client.listDataPoints("activity-level", range);
  await client.listDataPoints("exercise", range);
  assertEquals(
    filters[0],
    'daily_resting_heart_rate.date >= "2026-11-11" AND daily_resting_heart_rate.date < "2026-11-12"',
  );
  assert(filters[1].startsWith("activity_level.interval.start_time"));
  assert(filters[2].startsWith("exercise.interval.civil_start_time"));
});

Deno.test("pagination cycles and malformed payloads fail without accepting truncated data", async () => {
  const range = { startDate: "2026-11-11", endDate: "2026-11-12", timeZone: "UTC" };
  const cycle = new GoogleHealthClient(
    "test-access",
    async () => Response.json({ dataPoints: [], nextPageToken: "same" }),
  );
  await assertRejects(() => cycle.listDataPoints("sleep", range), "google_pagination");
  const malformed = new GoogleHealthClient(
    "test-access",
    async () => Response.json({ dataPoints: "wrong" }),
  );
  await assertRejects(() => malformed.listDataPoints("sleep", range), "google_points_response");
  const transport = new GoogleHealthClient("test-access", async () => {
    throw new Error("never expose test credentials");
  });
  await assertRejects(() => transport.getIdentity(), "google_transport_or_json");
});
