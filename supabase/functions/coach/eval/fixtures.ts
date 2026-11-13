import { addDays } from "../../_shared/dates.ts";
import type { DailyRow } from "../../_shared/coach_tools.ts";
import { EVAL_TODAY, type FixtureUser } from "./types.ts";

// Fixture users for the coach evaluation. Everything is deterministic: no randomness,
// so a number in an answer can always be traced back to a row here.
// Each full user has 35 days ending on EVAL_TODAY (2026-10-09 to 2026-11-12).

const DAYS = 35;
const FIRST_DAY = addDays(EVAL_TODAY, -(DAYS - 1));

type Values = Partial<Omit<DailyRow, "date" | "is_demo">>;

// Small repeating patterns, so days differ a little but stay predictable.
const SLEEP = [430, 440, 425, 435, 445, 420, 438];
const AWAKE = [28, 32, 25, 35, 30, 27, 33];
const RESTING_HR = [60, 61, 59, 60, 62, 60, 59];
const HRV = [44, 42, 46, 43, 41, 45, 44];
const STEPS = [9100, 8700, 9400, 8900, 9600, 8300, 9000];
const ZONE = [24, 20, 28, 22, 30, 18, 25];

function row(date: string, i: number, isDemo: boolean, over: Values = {}): DailyRow {
  const sleep = (over.sleep_minutes === undefined ? SLEEP[i % 7] : over.sleep_minutes) as
    | number
    | null;
  const awake = AWAKE[i % 7];
  // Wake-up is 07:00 Istanbul time (04:00 UTC) unless a bedtime is given.
  const wake = Date.parse(`${date}T04:00:00Z`);
  const base: DailyRow = {
    date,
    sleep_minutes: sleep,
    deep_min: sleep === null ? null : Math.round(sleep * 0.18),
    rem_min: sleep === null ? null : Math.round(sleep * 0.22),
    awake_min: sleep === null ? null : awake,
    sleep_efficiency: sleep === null ? null : Math.round((sleep / (sleep + awake)) * 1000) / 10,
    bedtime: sleep === null ? null : new Date(wake - (sleep + awake) * 60000).toISOString(),
    wake_time: sleep === null ? null : new Date(wake).toISOString(),
    resting_hr: RESTING_HR[i % 7],
    hrv_ms: HRV[i % 7],
    steps: STEPS[i % 7],
    active_zone_min: ZONE[i % 7],
    total_calories: 2200 + (i % 5) * 60,
    is_demo: isDemo,
  };
  return { ...base, ...over };
}

function build(
  isDemo: boolean,
  changes: Record<string, Values | null> = {},
  only?: (date: string) => boolean,
): DailyRow[] {
  const rows: DailyRow[] = [];
  for (let i = 0; i < DAYS; i++) {
    const date = addDays(FIRST_DAY, i);
    if (only && !only(date)) continue;
    if (changes[date] === null) continue; // null = no row at all for that day
    rows.push(row(date, i, isDemo, changes[date] ?? {}));
  }
  return rows;
}

// Two short nights with late bedtimes in the last week.
const BAD_WEEK: Record<string, Values> = {
  "2026-11-09": { sleep_minutes: 290, hrv_ms: 36, resting_hr: 64 },
  "2026-11-11": { sleep_minutes: 310, hrv_ms: 38, resting_hr: 63 },
};

// Steps rise and resting heart rate falls over the five weeks.
function activeChanges(): Record<string, Values> {
  const changes: Record<string, Values> = {};
  for (let i = 0; i < DAYS; i++) {
    const week = Math.floor(i / 7); // 0..4
    changes[addDays(FIRST_DAY, i)] = {
      steps: 6000 + week * 1500 + (i % 7) * 100,
      resting_hr: 64 - week - (i % 2),
      hrv_ms: 40 + week * 2 + (i % 3),
      active_zone_min: 15 + week * 8 + (i % 4),
    };
  }
  changes["2026-11-08"] = { ...changes["2026-11-08"], steps: 15400, active_zone_min: 72 };
  return changes;
}

export const FIXTURE_USERS: FixtureUser[] = [
  {
    id: "steady",
    description: "35 regular days. Nothing stands out.",
    isDemo: false,
    rows: build(false),
  },
  {
    id: "bad_week",
    description:
      "35 days. Two short nights in the last week: Nov 9 (290 min) and Nov 11 (310 min).",
    isDemo: false,
    rows: build(false, BAD_WEEK),
  },
  {
    id: "missing_week",
    description: "Four full weeks, then only 3 nights in the last week (Nov 6, 8 and 11).",
    isDemo: false,
    rows: build(false, {
      "2026-11-07": null,
      "2026-11-09": null,
      "2026-11-10": null,
      "2026-11-12": null,
    }),
  },
  {
    id: "gaps",
    description:
      "Days missing here and there (Oct 15, 22, 23, Nov 2, 7, 10). Nov 4 has steps but no sleep.",
    isDemo: false,
    rows: build(false, {
      "2026-10-15": null,
      "2026-10-22": null,
      "2026-10-23": null,
      "2026-11-02": null,
      "2026-11-07": null,
      "2026-11-10": null,
      "2026-11-04": { sleep_minutes: null },
    }),
  },
  {
    id: "new_user",
    description: "Only 5 days of data (Nov 8 to Nov 12).",
    isDemo: false,
    rows: build(false, {}, (date) => date >= "2026-11-08"),
  },
  {
    id: "active",
    description:
      "Steps rise from about 6,000 to about 12,000 a day and resting heart rate falls. Nov 8 is the top day (15,400 steps).",
    isDemo: false,
    rows: build(false, activeChanges()),
  },
  {
    id: "empty",
    description: "No data at all.",
    isDemo: false,
    rows: [],
  },
  {
    id: "demo",
    description: "Same as bad_week, but every row is flagged as demo data.",
    isDemo: true,
    rows: build(true, BAD_WEEK),
  },
];
