import { comparePeriods, dailyMetrics, type DailyRow, validateTool } from "./coach_tools.ts";
import { assert, assertEquals } from "./test_helpers.ts";

const rows: DailyRow[] = [
  { date: "2026-11-01", sleep_minutes: 100 },
  { date: "2026-11-02", sleep_minutes: null },
  { date: "2026-11-04", sleep_minutes: 200 },
  { date: "2026-11-05", sleep_minutes: 303 },
  { date: "2026-11-06", sleep_minutes: 404, is_demo: true },
];
const baseline: DailyRow[] = [1, 2, 3, 4].map((n) => ({
  date: "2026-10-0" + n,
  sleep_minutes: 200,
}));

Deno.test("coach computations exclude absent and null values and round to one decimal", () => {
  const comparison = comparePeriods(
    rows,
    baseline,
    "sleep_minutes",
    "2026-11-01",
    "2026-11-06",
    "2026-10-01",
    "2026-10-04",
  );
  assertEquals(comparison.a, {
    nights_with_data: 4,
    missing_dates: ["2026-11-02", "2026-11-03"],
    mean: 251.8,
    median: 251.5,
  });
  assertEquals(comparison.b.mean, 200);
  assertEquals(comparison.difference, 51.8);
  assertEquals(comparison.is_demo, true);
});

Deno.test("coach needs four observed values in both periods and ranks absolute deviations", () => {
  const comparison = comparePeriods(
    rows,
    baseline,
    "sleep_minutes",
    "2026-11-01",
    "2026-11-06",
    "2026-10-01",
    "2026-10-04",
  );
  assertEquals(comparison.enough_data, true);
  assertEquals(comparison.top_contributors, [
    { date: "2026-11-06", value: 404, deviation: 204 },
    { date: "2026-11-05", value: 303, deviation: 103 },
    { date: "2026-11-01", value: 100, deviation: -100 },
  ]);
  assertEquals(
    comparePeriods(
      rows.slice(0, -1),
      baseline,
      "sleep_minutes",
      "2026-11-01",
      "2026-11-06",
      "2026-10-01",
      "2026-10-04",
    ).enough_data,
    false,
  );
  assertEquals(
    comparePeriods(
      rows,
      baseline.slice(1),
      "sleep_minutes",
      "2026-11-01",
      "2026-11-06",
      "2026-10-01",
      "2026-10-04",
    ).enough_data,
    false,
  );
  const empty = comparePeriods(
    [],
    [],
    "steps",
    "2026-11-01",
    "2026-11-02",
    "2026-10-01",
    "2026-10-02",
  );
  assertEquals(empty.a.mean, null);
  assertEquals(empty.difference, null);
  assertEquals(empty.top_contributors, []);
});

Deno.test("daily metrics project only allowed fields and mark missing and demo dates", () => {
  const result = dailyMetrics(rows, "2026-11-03", "2026-11-06");
  assertEquals(result.missing_dates, ["2026-11-03"]);
  assertEquals(result.days.map((day) => day.date), ["2026-11-04", "2026-11-05", "2026-11-06"]);
  assertEquals(result.days[0].steps, null);
  assertEquals(result.is_demo, true);
  assert(!("is_demo" in result.days[0]));
});

Deno.test("coach tool input rejects invalid dates, reversed or oversized ranges and unknown metrics", () => {
  for (
    const [name, input] of [
      ["get_daily_metrics", { start_date: "2026-02-30", end_date: "2026-03-01" }],
      ["get_daily_metrics", { start_date: "2026-11-02", end_date: "2026-11-01" }],
      ["get_daily_metrics", { start_date: "2026-01-01", end_date: "2026-04-03" }],
      ["get_daily_metrics", { start_date: 1, end_date: "2026-11-01" }],
      ["compare_periods", {
        metric: "secret",
        a_start: "2026-11-01",
        a_end: "2026-11-02",
        b_start: "2026-10-01",
        b_end: "2026-10-02",
      }],
    ] as const
  ) {
    let rejected = false;
    try {
      validateTool(name, input);
    } catch {
      rejected = true;
    }
    assert(rejected);
  }
  assertEquals(
    validateTool("get_daily_metrics", { start_date: "2026-01-01", end_date: "2026-04-02" }),
    {
      start_date: "2026-01-01",
      end_date: "2026-04-02",
    },
  );
});
