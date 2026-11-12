import { dayBounds } from "./dates.ts";
import { type DataType, mapDailyMetrics, READ_METHOD } from "./mapping.ts";
import { assertEquals } from "./test_helpers.ts";
import sleep from "./fixtures/sleep.json" with { type: "json" };
import steps from "./fixtures/steps.json" with { type: "json" };
import azm from "./fixtures/active-zone-minutes.json" with { type: "json" };
import activity from "./fixtures/activity-level.json" with { type: "json" };
import calories from "./fixtures/total-calories.json" with { type: "json" };
import resting from "./fixtures/daily-resting-heart-rate.json" with { type: "json" };
import hrv from "./fixtures/daily-heart-rate-variability.json" with { type: "json" };
import oxygen from "./fixtures/daily-oxygen-saturation.json" with { type: "json" };
import exercise from "./fixtures/exercise.json" with { type: "json" };
import empty from "./fixtures/empty-responses.json" with { type: "json" };

const date = "2026-11-11";
const timeZone = "Europe/Istanbul";
const cases: [DataType, unknown, Record<string, unknown>][] = [
  ["sleep", sleep, {
    sleep_minutes: 450,
    sleep_efficiency: 93.75,
    deep_min: 90,
    rem_min: 100,
    light_min: 260,
    awake_min: 30,
    bedtime: "2026-11-10T20:00:00.000Z",
    wake_time: "2026-11-11T04:00:00.000Z",
  }],
  ["steps", steps, { steps: 8432 }],
  ["active-zone-minutes", azm, { active_zone_min: 36 }],
  ["activity-level", activity, { active_min: 30 }],
  ["total-calories", calories, { total_calories: 2188 }],
  ["daily-resting-heart-rate", resting, { resting_hr: 58 }],
  ["daily-heart-rate-variability", hrv, { hrv_ms: 47.3 }],
  ["daily-oxygen-saturation", oxygen, { spo2_avg: 97.2 }],
  ["exercise", exercise, { exercise_count: 2 }],
];

for (const [type, fixture, expected] of cases) {
  Deno.test(`${type} documented-shape fixture maps only its expected columns`, () => {
    const before = JSON.stringify(fixture);
    assertEquals(mapDailyMetrics(type, fixture, date, timeZone), expected);
    assertEquals(JSON.stringify(fixture), before);
  });
  Deno.test(`${type} empty responses leave all columns unchanged`, () => {
    for (const fixture of empty) assertEquals(mapDailyMetrics(type, fixture, date, timeZone), {});
  });
}

Deno.test("read methods match API_NOTES for every supported type", () => {
  assertEquals(READ_METHOD, {
    sleep: "list",
    steps: "rollup",
    "active-zone-minutes": "rollup",
    "activity-level": "list",
    "total-calories": "rollup",
    "daily-resting-heart-rate": "list",
    "daily-heart-rate-variability": "list",
    "daily-oxygen-saturation": "list",
    exercise: "list",
  });
});

Deno.test("sleep belongs to the wake date across midnight", () => {
  assertEquals(mapDailyMetrics("sleep", sleep, "2026-11-10", "UTC"), {});
  assertEquals(mapDailyMetrics("sleep", sleep, date, "UTC").sleep_minutes, 450);
});

Deno.test("sleep wake date uses IANA timezone instead of the UTC date", () => {
  const fixture = structuredClone(sleep);
  fixture.dataPoints[0].sleep.interval.startTime = "2026-11-10T18:00:00Z";
  fixture.dataPoints[0].sleep.interval.endTime = "2026-11-10T22:30:00Z";
  assertEquals(mapDailyMetrics("sleep", fixture, date, timeZone).sleep_minutes, 450);
  assertEquals(mapDailyMetrics("sleep", fixture, "2026-11-10", timeZone), {});
  assertEquals(mapDailyMetrics("sleep", fixture, date, "UTC"), {});
});

Deno.test("sleep selects the longest marked main session, ignoring a longer non-main session", () => {
  const main = structuredClone(sleep.dataPoints[0]);
  const nap = structuredClone(main);
  nap.name += "nap";
  nap.sleep.metadata.mainSleep = false;
  nap.sleep.interval.startTime = "2026-11-10T16:00:00Z";
  nap.sleep.summary.minutesAsleep = "600";
  const shorter = structuredClone(main);
  shorter.name += "short";
  shorter.sleep.interval.startTime = "2026-11-11T01:00:00Z";
  shorter.sleep.summary.minutesAsleep = "160";
  const response = { dataPoints: [nap, shorter, main] };
  assertEquals(mapDailyMetrics("sleep", response, date, timeZone).sleep_minutes, 450);
  nap.sleep.metadata.mainSleep = true;
  assertEquals(mapDailyMetrics("sleep", response, date, timeZone).sleep_minutes, 600);
});

Deno.test("classic sleep does not invent absent stage minutes or efficiency", () => {
  const response = {
    dataPoints: [{
      sleep: {
        interval: sleep.dataPoints[0].sleep.interval,
        type: "CLASSIC",
        summary: { minutesAsleep: "420" },
      },
    }],
  };
  assertEquals(mapDailyMetrics("sleep", response, date, timeZone), {
    sleep_minutes: 420,
    bedtime: "2026-11-10T20:00:00.000Z",
    wake_time: "2026-11-11T04:00:00.000Z",
  });
});

Deno.test("explicit zero is data; null, missing, invalid and other-date values are not", () => {
  const fixture = structuredClone(steps);
  fixture.rollupDataPoints[0].steps.countSum = "0";
  assertEquals(mapDailyMetrics("steps", fixture, date, timeZone), { steps: 0 });
  for (const value of [null, "", "NaN", -1, false]) {
    assertEquals(
      mapDailyMetrics(
        "steps",
        {
          rollupDataPoints: [{
            civilStartTime: { date: { year: 2026, month: 11, day: 11 } },
            steps: { countSum: value },
          }],
        },
        date,
        timeZone,
      ),
      {},
    );
  }
  assertEquals(mapDailyMetrics("daily-heart-rate-variability", hrv, "2026-11-12", timeZone), {});
  assertEquals(mapDailyMetrics("steps", steps, "2026-11-12", timeZone), {});
});

Deno.test("activity clips to the local date and unions overlapping intervals", () => {
  const response = {
    dataPoints: [{
      activityLevel: {
        activityLevelType: "VERY_ACTIVE",
        interval: { startTime: "2026-11-10T20:50:00Z", endTime: "2026-11-10T21:10:00Z" },
      },
    }],
  };
  assertEquals(mapDailyMetrics("activity-level", response, date, timeZone), { active_min: 10 });
  const sedentary = { dataPoints: [activity.dataPoints[2]] };
  assertEquals(mapDailyMetrics("activity-level", sedentary, date, timeZone), { active_min: 0 });
});

Deno.test("exercise resources are deduplicated and attributed by local start date", () => {
  assertEquals(
    mapDailyMetrics(
      "exercise",
      { dataPoints: [...exercise.dataPoints, exercise.dataPoints[0]] },
      date,
      timeZone,
    ),
    { exercise_count: 2 },
  );
  const fixture = structuredClone(exercise);
  fixture.dataPoints[0].exercise.interval.startTime = "2026-11-10T23:00:00Z";
  assertEquals(mapDailyMetrics("exercise", fixture, date, timeZone), { exercise_count: 2 });
  assertEquals(mapDailyMetrics("exercise", fixture, date, "UTC"), { exercise_count: 1 });
});

Deno.test("civil day bounds account for DST and Istanbul offset", () => {
  const spring = dayBounds("2026-03-08", "America/New_York");
  const autumn = dayBounds("2026-11-01", "America/New_York");
  assertEquals((spring.end - spring.start) / 3600000, 23);
  assertEquals((autumn.end - autumn.start) / 3600000, 25);
  assertEquals(new Date(dayBounds(date, timeZone).start).toISOString(), "2026-11-10T21:00:00.000Z");
});
