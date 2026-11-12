import { dateParts, dayBounds, localDate } from "./dates.ts";

export const READ_METHOD = {
  sleep: "list",
  steps: "rollup",
  "active-zone-minutes": "rollup",
  "activity-level": "list",
  "total-calories": "rollup",
  "daily-resting-heart-rate": "list",
  "daily-heart-rate-variability": "list",
  "daily-oxygen-saturation": "list",
  exercise: "list",
} as const;

export type DataType = keyof typeof READ_METHOD;

export function isDataType(value: string): value is DataType {
  return Object.hasOwn(READ_METHOD, value);
}

export interface DailyMetrics {
  sleep_minutes: number;
  sleep_efficiency: number;
  deep_min: number;
  rem_min: number;
  light_min: number;
  awake_min: number;
  bedtime: string;
  wake_time: string;
  steps: number;
  active_zone_min: number;
  active_min: number;
  total_calories: number;
  resting_hr: number;
  hrv_ms: number;
  spo2_avg: number;
  exercise_count: number;
}

export type MetricsUpdate = Partial<DailyMetrics>;

function object(value: unknown): Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? value as Record<string, unknown>
    : {};
}

function array(value: unknown): Record<string, unknown>[] {
  return Array.isArray(value) ? value.map(object) : [];
}

function number(value: unknown): number | undefined {
  if (typeof value !== "number" && (typeof value !== "string" || !/^\d+(\.\d+)?$/.test(value))) {
    return;
  }
  const result = Number(value);
  return Number.isFinite(result) && result >= 0 && result <= Number.MAX_SAFE_INTEGER
    ? result
    : undefined;
}

function instant(value: unknown): number | undefined {
  if (typeof value !== "string" || !/T.*(?:Z|[+-]\d\d:\d\d)$/.test(value)) return;
  const time = Date.parse(value);
  return Number.isFinite(time) ? time : undefined;
}

function wireDate(value: unknown): string | undefined {
  const item = object(value);
  if (
    !Number.isInteger(item.year) || !Number.isInteger(item.month) || !Number.isInteger(item.day)
  ) return;
  const date = `${String(item.year).padStart(4, "0")}-${String(item.month).padStart(2, "0")}-${
    String(item.day).padStart(2, "0")
  }`;
  try {
    dateParts(date);
    return date;
  } catch {
    return;
  }
}

function uniquePoints(response: unknown): Record<string, unknown>[] {
  const seen = new Set<string>();
  return array(object(response).dataPoints).filter((point) => {
    if (typeof point.name !== "string") return true;
    if (seen.has(point.name)) return false;
    seen.add(point.name);
    return true;
  });
}

function sleep(points: Record<string, unknown>[], date: string, timeZone: string): MetricsUpdate {
  // UNVERIFIED: validate documented sleep.summary, metadata.mainSleep and stagesSummary on a device;
  // prefer the longest marked mainSleep, falling back to the longest session if flags are absent.
  const sessions = points.map((point) => object(point.sleep)).filter((session) => {
    const interval = object(session.interval);
    const start = instant(interval.startTime);
    const end = instant(interval.endTime);
    return start !== undefined && end !== undefined && end > start &&
      localDate(end, timeZone) === date;
  });
  const mains = sessions.filter((session) => object(session.metadata).mainSleep === true);
  const candidates = mains.length ? mains : sessions;
  candidates.sort((a, b) => {
    const duration = (session: Record<string, unknown>) => {
      const interval = object(session.interval);
      return instant(interval.endTime)! - instant(interval.startTime)!;
    };
    return duration(b) - duration(a);
  });
  const session = candidates[0];
  if (!session) return {};
  const interval = object(session.interval);
  const summary = object(session.summary);
  const result: MetricsUpdate = {
    bedtime: new Date(instant(interval.startTime)!).toISOString(),
    wake_time: new Date(instant(interval.endTime)!).toISOString(),
  };
  const asleep = number(summary.minutesAsleep);
  const period = number(summary.minutesInSleepPeriod);
  if (asleep !== undefined) result.sleep_minutes = Math.round(asleep);
  // UNVERIFIED: compare this derived percentage (minutesAsleep / minutesInSleepPeriod) to the app.
  if (asleep !== undefined && period !== undefined && period > 0 && asleep <= period) {
    result.sleep_efficiency = Math.round(asleep / period * 10000) / 100;
  }
  const stageColumns = {
    DEEP: "deep_min",
    REM: "rem_min",
    LIGHT: "light_min",
    AWAKE: "awake_min",
  } as const;
  for (const [stage, column] of Object.entries(stageColumns)) {
    const values = array(summary.stagesSummary).filter((item) => item.type === stage)
      .map((item) => number(item.minutes)).filter((value): value is number => value !== undefined);
    if (values.length) result[column] = Math.round(values.reduce((a, b) => a + b, 0));
  }
  const awake = number(summary.minutesAwake);
  if (awake !== undefined) result.awake_min = Math.round(awake);
  return result;
}

function activity(
  points: Record<string, unknown>[],
  date: string,
  timeZone: string,
): MetricsUpdate {
  const bounds = dayBounds(date, timeZone);
  const intervals: [number, number][] = [];
  let observed = false;
  // UNVERIFIED: confirm activityLevelType intervals represent elapsed activity time; union overlapping
  // moderately/very-active intervals across sources before rounding to whole minutes.
  for (const point of points) {
    const value = object(point.activityLevel);
    const interval = object(value.interval);
    const start = instant(interval.startTime);
    const end = instant(interval.endTime);
    if (
      start === undefined || end === undefined || end <= start || end <= bounds.start ||
      start >= bounds.end
    ) continue;
    if (
      !["SEDENTARY", "LIGHTLY_ACTIVE", "MODERATELY_ACTIVE", "VERY_ACTIVE"].includes(
        String(value.activityLevelType),
      )
    ) continue;
    observed = true;
    if (
      value.activityLevelType === "MODERATELY_ACTIVE" || value.activityLevelType === "VERY_ACTIVE"
    ) {
      intervals.push([Math.max(start, bounds.start), Math.min(end, bounds.end)]);
    }
  }
  if (!observed) return {};
  intervals.sort((a, b) => a[0] - b[0]);
  let duration = 0;
  let priorEnd = bounds.start;
  for (const [start, end] of intervals) {
    duration += Math.max(0, end - Math.max(start, priorEnd));
    priorEnd = Math.max(priorEnd, end);
  }
  return { active_min: Math.round(duration / 60000) };
}

export function mapDailyMetrics(
  dataType: DataType,
  response: unknown,
  date: string,
  timeZone: string,
): MetricsUpdate {
  dateParts(date);
  const points = uniquePoints(response);
  if (dataType === "sleep") return sleep(points, date, timeZone);
  if (dataType === "activity-level") return activity(points, date, timeZone);
  if (dataType === "exercise") {
    // UNVERIFIED: count distinct exercise resources by start date in the profile timezone;
    // check duplicate sessions from different sources against a real account.
    const sessions = points.filter((point) => {
      const interval = object(object(point.exercise).interval);
      const start = instant(interval.startTime);
      const end = instant(interval.endTime);
      return start !== undefined && end !== undefined && end > start &&
        localDate(start, timeZone) === date;
    });
    return sessions.length ? { exercise_count: sessions.length } : {};
  }
  const dailyFields = {
    "daily-resting-heart-rate": ["dailyRestingHeartRate", "beatsPerMinute", "resting_hr"],
    "daily-heart-rate-variability": [
      "dailyHeartRateVariability",
      "averageHeartRateVariabilityMilliseconds",
      "hrv_ms",
    ],
    "daily-oxygen-saturation": ["dailyOxygenSaturation", "averagePercentage", "spo2_avg"],
  } as const;
  if (dataType in dailyFields) {
    const [payload, field, column] = dailyFields[dataType as keyof typeof dailyFields];
    // UNVERIFIED: confirm daily payload date/units; if several sources supply one date, use the
    // first valid daily record in API order rather than summing or averaging Google's daily values.
    for (const point of points) {
      const value = object(point[payload]);
      const metric = number(value[field]);
      if (
        wireDate(value.date) === date && metric !== undefined &&
        (column !== "spo2_avg" || metric <= 100)
      ) {
        return { [column]: metric };
      }
    }
    return {};
  }
  // UNVERIFIED: confirm rollupDataPoints civilStartTime.date and camelCase rollup payloads on-device.
  const bucket = array(object(response).rollupDataPoints).find((point) =>
    wireDate(object(point.civilStartTime).date) === date
  );
  if (!bucket) return {};
  if (dataType === "active-zone-minutes") {
    const value = object(bucket.activeZoneMinutes);
    // UNVERIFIED: documented zone sums are already earned AZM; do not double-weight cardio/peak.
    const values = ["sumInFatBurnHeartZone", "sumInCardioHeartZone", "sumInPeakHeartZone"]
      .map((field) => number(value[field])).filter((value): value is number => value !== undefined);
    return values.length ? { active_zone_min: Math.round(values.reduce((a, b) => a + b, 0)) } : {};
  }
  const value = dataType === "steps"
    ? number(object(bucket.steps).countSum)
    : number(object(bucket.totalCalories).kcalSum);
  if (value === undefined) return {};
  return dataType === "steps"
    ? { steps: Math.round(value) }
    : { total_calories: Math.round(value) };
}
