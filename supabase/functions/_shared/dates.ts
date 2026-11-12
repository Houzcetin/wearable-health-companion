const formatters = new Map<string, Intl.DateTimeFormat>();

export function localDate(instant: string | number, timeZone: string): string {
  let formatter = formatters.get(timeZone);
  if (!formatter) {
    formatter = new Intl.DateTimeFormat("en-CA", {
      timeZone,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
    });
    formatters.set(timeZone, formatter);
  }
  const parts = formatter.formatToParts(new Date(instant));
  return ["year", "month", "day"].map((type) => parts.find((part) => part.type === type)!.value)
    .join("-");
}

export function dateParts(date: string): { year: number; month: number; day: number } {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) throw new Error("invalid_date");
  const instant = new Date(`${date}T00:00:00Z`);
  if (!Number.isFinite(instant.getTime()) || instant.toISOString().slice(0, 10) !== date) {
    throw new Error("invalid_date");
  }
  return {
    year: instant.getUTCFullYear(),
    month: instant.getUTCMonth() + 1,
    day: instant.getUTCDate(),
  };
}

export function addDays(date: string, days: number): string {
  dateParts(date);
  return new Date(Date.parse(`${date}T00:00:00Z`) + days * 86400000).toISOString().slice(0, 10);
}

function dayStart(date: string, timeZone: string): number {
  dateParts(date);
  const center = Date.parse(`${date}T00:00:00Z`);
  let low = center - 36 * 3600000;
  let high = center + 36 * 3600000;
  // Find the first instant of the civil date, including days with a DST change at midnight.
  while (high - low > 1) {
    const middle = Math.floor((low + high) / 2);
    if (localDate(middle, timeZone) < date) low = middle;
    else high = middle;
  }
  return high;
}

export function dayBounds(date: string, timeZone: string): { start: number; end: number } {
  return { start: dayStart(date, timeZone), end: dayStart(addDays(date, 1), timeZone) };
}
