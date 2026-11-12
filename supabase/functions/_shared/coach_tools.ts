import { addDays, dateParts } from "./dates.ts";
import { record } from "./google.ts";

export const METRICS = [
  "sleep_minutes",
  "resting_hr",
  "hrv_ms",
  "steps",
  "active_zone_min",
  "deep_min",
  "rem_min",
  "awake_min",
] as const;
export type Metric = typeof METRICS[number];
export const DAILY_FIELDS = [
  "date",
  "sleep_minutes",
  "deep_min",
  "rem_min",
  "awake_min",
  "sleep_efficiency",
  "bedtime",
  "wake_time",
  "resting_hr",
  "hrv_ms",
  "steps",
  "active_zone_min",
  "total_calories",
] as const;
export const DAILY_SELECT = [...DAILY_FIELDS, "is_demo"].join(",");
export type DailyRow =
  & { date: string; is_demo?: boolean }
  & Partial<
    Record<Exclude<typeof DAILY_FIELDS[number], "date">, number | string | null>
  >;

export function rangeDates(start: unknown, end: unknown): string[] {
  if (typeof start !== "string" || typeof end !== "string") throw new Error("invalid_tool_input");
  try {
    dateParts(start);
    dateParts(end);
  } catch {
    throw new Error("invalid_tool_input");
  }
  const count = (Date.parse(end) - Date.parse(start)) / 86400000 + 1;
  if (count < 1 || count > 92) throw new Error("invalid_tool_input");
  return Array.from({ length: count }, (_, i) => addDays(start, i));
}

export function validateTool(name: string, input: unknown): Record<string, string> {
  const value = record(input);
  if (name === "get_daily_metrics") {
    rangeDates(value.start_date, value.end_date);
    return { start_date: value.start_date as string, end_date: value.end_date as string };
  }
  if (name === "compare_periods" && METRICS.includes(value.metric as Metric)) {
    rangeDates(value.a_start, value.a_end);
    rangeDates(value.b_start, value.b_end);
    return {
      metric: value.metric as string,
      a_start: value.a_start as string,
      a_end: value.a_end as string,
      b_start: value.b_start as string,
      b_end: value.b_end as string,
    };
  }
  throw new Error("invalid_tool_input");
}

export function dailyMetrics(rows: DailyRow[], start: string, end: string) {
  const dates = rangeDates(start, end);
  const present = new Map(
    rows.filter((row) => dates.includes(row.date)).map((row) => [row.date, row]),
  );
  return {
    days: dates.filter((date) => present.has(date)).map((date) => {
      const row = present.get(date)!;
      return Object.fromEntries(DAILY_FIELDS.map((field) => [field, row[field] ?? null]));
    }),
    missing_dates: dates.filter((date) => !present.has(date)),
    is_demo: [...present.values()].some((row) => row.is_demo === true),
  };
}

function round(value: number): number {
  return Math.round((value + Number.EPSILON) * 10) / 10;
}

function period(rows: DailyRow[], metric: Metric, start: string, end: string) {
  const dates = rangeDates(start, end);
  const values = rows.filter((row) =>
    dates.includes(row.date) && typeof row[metric] === "number" && Number.isFinite(row[metric])
  ).map((row) => ({ date: row.date, value: row[metric] as number }));
  const sorted = values.map((row) => row.value).sort((a, b) => a - b);
  const n = sorted.length;
  const mean = n ? sorted.reduce((sum, value) => sum + value, 0) / n : null;
  const median = n ? (sorted[Math.floor((n - 1) / 2)] + sorted[Math.floor(n / 2)]) / 2 : null;
  return {
    values,
    mean,
    summary: {
      nights_with_data: n,
      missing_dates: dates.filter((date) => !values.some((row) => row.date === date)),
      mean: mean === null ? null : round(mean),
      median: median === null ? null : round(median),
    },
  };
}

export function comparePeriods(
  aRows: DailyRow[],
  bRows: DailyRow[],
  metric: Metric,
  aStart: string,
  aEnd: string,
  bStart: string,
  bEnd: string,
) {
  const a = period(aRows, metric, aStart, aEnd);
  const b = period(bRows, metric, bStart, bEnd);
  const contributors = b.mean === null ? [] : a.values.map((row) => ({
    ...row,
    deviation: row.value - b.mean!,
  })).sort((left, right) =>
    Math.abs(right.deviation) - Math.abs(left.deviation) || left.date.localeCompare(right.date)
  ).slice(0, 3).map((row) => ({ ...row, deviation: round(row.deviation) }));
  return {
    a: a.summary,
    b: b.summary,
    difference: a.mean === null || b.mean === null ? null : round(a.mean - b.mean),
    top_contributors: contributors,
    enough_data: a.values.length >= 4 && b.values.length >= 4,
    is_demo: [...aRows, ...bRows].some((row) => row.is_demo === true),
  };
}

const dateProperty = { type: "string", pattern: "^\\d{4}-\\d{2}-\\d{2}$" };
export const COACH_TOOLS = [
  {
    name: "get_daily_metrics",
    description: "Read the user's daily aggregates and missing dates for up to 92 inclusive dates.",
    input_schema: {
      type: "object" as const,
      properties: { start_date: dateProperty, end_date: dateProperty },
      required: ["start_date", "end_date"],
      additionalProperties: false,
    },
  },
  {
    name: "compare_periods",
    description: "Compare two periods, excluding missing values, and rank the largest deviations.",
    input_schema: {
      type: "object" as const,
      properties: {
        metric: { type: "string", enum: [...METRICS] },
        a_start: dateProperty,
        a_end: dateProperty,
        b_start: dateProperty,
        b_end: dateProperty,
      },
      required: ["metric", "a_start", "a_end", "b_start", "b_end"],
      additionalProperties: false,
    },
  },
];
