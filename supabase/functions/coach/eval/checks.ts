import { dateParts } from "../../_shared/dates.ts";
import { EVAL_TODAY, type FixtureUser, type Question } from "./types.ts";

export const CHECK_NAMES = [
  "numbers_match",
  "tool_called",
  "dates_shown",
  "expect",
  "insufficient_data",
  "no_causal",
  "no_medical",
  "demo_mention",
  "format",
] as const;

export interface ToolFact {
  name: string;
  input: unknown;
  result: unknown;
}

export interface CheckInput {
  question: Question;
  user: FixtureUser;
  answer: string;
  tools: ToolFact[];
  isDemo: boolean;
}

export interface CheckResult {
  name: typeof CHECK_NAMES[number];
  pass: boolean;
  detail: string;
}

const result = (name: CheckResult["name"], failures: string[]): CheckResult => ({
  name,
  pass: failures.length === 0,
  detail: failures.length ? failures.join("; ") : "OK",
});

const object = (value: unknown): Record<string, unknown> =>
  value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : {};

const MONTHS = [
  "jan(?:uary)?",
  "feb(?:ruary)?",
  "mar(?:ch)?",
  "apr(?:il)?",
  "may",
  "jun(?:e)?",
  "jul(?:y)?",
  "aug(?:ust)?",
  "sep(?:t(?:ember)?)?",
  "oct(?:ober)?",
  "nov(?:ember)?",
  "dec(?:ember)?",
];
const MONTH = `(?:${MONTHS.join("|")})\\.?`;
const DAY = "(\\d{1,2})(?:st|nd|rd|th)?";
const YEAR = "(?:,?\\s+(\\d{4}))?";

interface NamedDate {
  date: string;
  text: string;
  start: number;
  end: number;
}

// Deliberately uses the fixed eval year, never the machine's current date or locale.
export const namedDates = (answer: string): NamedDate[] => {
  const dates: NamedDate[] = [];
  const add = (match: RegExpMatchArray, date: string) => {
    dates.push({ date, text: match[0], start: match.index!, end: match.index! + match[0].length });
  };
  for (const match of answer.matchAll(/\b\d{4}-\d{2}-\d{2}\b/g)) add(match, match[0]);
  const monthIndex = (text: string) =>
    MONTHS.findIndex((pattern) => new RegExp(`^${pattern}\\.?$`, "i").test(text)) + 1;
  for (const monthFirst of [true, false]) {
    const regex = new RegExp(
      monthFirst ? `\\b(${MONTH})\\s+${DAY}${YEAR}\\b` : `\\b${DAY}\\s+(${MONTH})${YEAR}\\b`,
      "gi",
    );
    for (const match of answer.matchAll(regex)) {
      const day = match[monthFirst ? 2 : 1];
      const month = monthIndex(match[monthFirst ? 1 : 2]);
      const year = match[3] ?? EVAL_TODAY.slice(0, 4);
      add(match, `${year}-${String(month).padStart(2, "0")}-${day.padStart(2, "0")}`);
    }
  }
  // Lists and ranges that share one month: "15, 22 and 23 October", "6 to 12 November",
  // "October 9, 11 and 13", "October 9–15". Each day number becomes its own date.
  const sep = "\\s*(?:,\\s*(?:and\\s+)?|and|to|through|until|[–-])\\s*";
  const item = "\\d{1,2}(?:st|nd|rd|th)?";
  // A list item must not be the start of a measurement ("November 12, 7 hours").
  // A sentence comma or full stop after the last day is fine; "12,100" or "7.5" is not a day.
  const notUnit =
    "(?!\\d|[:.]\\d|,\\d{3}|\\s*(?:h\\b|hours?|hrs?|min|minutes?|m\\b|ms|bpm|steps|%))";
  const lists = [
    { regex: new RegExp(`\\b(${item}(?:${sep}${item})+)\\s+(${MONTH})(?![a-z])`, "gi"), days: 1 },
    {
      regex: new RegExp(`\\b(${MONTH})\\s+(${item}(?:${sep}${item}${notUnit})+)`, "gi"),
      days: 2,
    },
  ];
  for (const { regex, days } of lists) {
    for (const match of answer.matchAll(regex)) {
      const month = monthIndex(match[days === 1 ? 2 : 1]);
      for (const day of match[days].match(/\d{1,2}/g) ?? []) {
        add(
          match,
          `${EVAL_TODAY.slice(0, 4)}-${String(month).padStart(2, "0")}-${day.padStart(2, "0")}`,
        );
      }
    }
  }
  return dates.sort((a, b) => a.start - b.start);
};

const validDate = (date: unknown): date is string => {
  try {
    if (typeof date !== "string") return false;
    dateParts(date);
    return true;
  } catch {
    return false;
  }
};

interface AnswerNumber {
  text: string;
  value: number;
  tolerance: number;
  duration: boolean;
}

const metricNumbers = (answer: string): AnswerNumber[] => {
  let text = answer;
  const mask = (start: number, end: number) => {
    text = text.slice(0, start) + " ".repeat(end - start) + text.slice(end);
  };
  for (const date of namedDates(answer)) mask(date.start, date.end);
  // Clock times (23:09, 7:00 am, 11 pm) and bare years are not metric values.
  text = text.replace(
    /\b\d{1,2}:\d{2}(?:\s*[ap]\.?m\.?)?|\b\d{1,2}\s*[ap]\.?m\.?(?![a-z])|\b20\d{2}\b/gi,
    (found) => " ".repeat(found.length),
  );
  text = text.replace(
    /\b\d+(?:\.\d+)?\s*[-–]?\s*(?:days?|nights?|weeks?)\b/gi,
    (count) => Number.parseFloat(count) <= 35 ? " ".repeat(count.length) : count,
  );
  const numbers: AnswerNumber[] = [];
  const number = "(?:\\d{1,3}(?:,\\d{3})+|\\d+)(?:\\.\\d+)?";
  const hours = new RegExp(
    `\\b(${number})\\s*(?:hours?|hrs?|h)\\b(?:\\s*(?:and\\s+)?(${number})\\s*(?:minutes?|mins?|m)\\b)?`,
    "gi",
  );
  // The boundary after h must also accept the compact spelling 6h 52m.
  for (const match of text.matchAll(hours)) {
    numbers.push({
      text: match[0],
      value: Number(match[1].replaceAll(",", "")) * 60 +
        Number((match[2] ?? "0").replaceAll(",", "")),
      tolerance: 5,
      duration: true,
    });
    mask(match.index!, match.index! + match[0].length);
  }
  const minutes = new RegExp(`\\b(${number})\\s*(?:minutes?|mins?|m)\\b`, "gi");
  for (const match of text.matchAll(minutes)) {
    numbers.push({
      text: match[0],
      value: Number(match[1].replaceAll(",", "")),
      tolerance: 5,
      duration: true,
    });
    mask(match.index!, match.index! + match[0].length);
  }
  for (const match of text.matchAll(new RegExp(`[-+]?${number}`, "g"))) {
    const value = Number(match[0].replaceAll(",", ""));
    numbers.push({
      text: match[0],
      value,
      tolerance: match[0].includes(".") ? 0.1 : 1,
      duration: false,
    });
  }
  return numbers;
};

interface Candidate {
  value: number;
  duration: boolean;
}
const durationMetric = (metric: string) => metric === "sleep_minutes" || metric.endsWith("_min");

const candidates = (tools: ToolFact[]): Candidate[] => {
  const values: Candidate[] = [];
  const groups = new Map<string, number[]>();
  const add = (value: number, metric: string, deriveDifference = true) => {
    if (!Number.isFinite(value)) return;
    values.push({ value, duration: durationMetric(metric) });
    // Deltas are already derived; subtracting a delta again invents unrelated candidates.
    if (!deriveDifference) return;
    const group = groups.get(metric) ?? [];
    group.push(value);
    groups.set(metric, group);
  };
  for (const tool of tools) {
    const metric = String(object(tool.input).metric ?? "");
    const walk = (node: unknown, key = "") => {
      if (typeof node === "number") {
        // compare_periods uses value/mean/median/deviation instead of metric field names.
        add(
          node,
          ["value", "mean", "median", "difference", "deviation"].includes(key) ? metric : key,
          !["difference", "deviation"].includes(key),
        );
      } else if (Array.isArray(node)) {
        // A list's length is a count the coach may state ("4 missing nights").
        values.push({ value: node.length, duration: false });
        node.forEach((item) => walk(item, key));
      } else {
        Object.entries(object(node)).forEach(([field, value]) => walk(value, field));
      }
    };
    walk(tool.result);
    // Each daily result is a series. Do not mix summaries, counts, or unrelated metrics into a mean.
    const days = object(tool.result).days;
    if (Array.isArray(days)) {
      const fields = new Map<string, number[]>();
      for (const day of days) {
        for (const [field, value] of Object.entries(object(day))) {
          if (typeof value !== "number" || !Number.isFinite(value)) continue;
          const series = fields.get(field) ?? [];
          series.push(value);
          fields.set(field, series);
        }
      }
      for (const [field, series] of fields) {
        const sorted = series.slice().sort((a, b) => a - b);
        add(series.reduce((sum, value) => sum + value, 0) / series.length, field);
        add(
          (sorted[Math.floor((sorted.length - 1) / 2)] + sorted[Math.floor(sorted.length / 2)]) / 2,
          field,
        );
      }
    }
  }
  // Differences stay within a metric; a step count must not substantiate an HRV difference.
  for (const [metric, group] of groups) {
    const distinct = [...new Set(group)];
    for (let a = 0; a < distinct.length; a++) {
      for (let b = a + 1; b < distinct.length; b++) {
        values.push({ value: distinct[a] - distinct[b], duration: durationMetric(metric) });
      }
    }
  }
  return values;
};

// Round reference thresholds a coach may mention without them being data (a daily step goal).
const REFERENCE_VALUES = [10000];

export const numbersMatch = ({ question, answer, tools }: CheckInput): CheckResult => {
  const fromTools = candidates(tools);
  // Numbers the user typed may be repeated, and compared with the data ("1 h 47 min short of 9 h").
  const fromQuestion = metricNumbers(question.question).map(({ value, duration }) => ({
    value,
    duration,
  }));
  const allowed = [
    ...fromTools,
    ...fromQuestion,
    ...REFERENCE_VALUES.map((value) => ({ value, duration: false })),
    ...fromQuestion.flatMap((asked) =>
      fromTools.filter((tool) => tool.duration === asked.duration)
        .map((tool) => ({ value: asked.value - tool.value, duration: asked.duration }))
    ),
  ];
  const failures = metricNumbers(answer).filter((number) =>
    !allowed.some((candidate) =>
      (!number.duration || candidate.duration) &&
      Math.abs(Math.abs(candidate.value) - Math.abs(number.value)) <= number.tolerance + 1e-9
    )
  );
  return result("numbers_match", failures.map((number) => `Unsupported number: ${number.text}`));
};

export const toolCalled = ({ question, answer, tools }: CheckInput): CheckResult => {
  // Repeating a number the user typed ("I can't confirm 9 hours") needs no data.
  const asked = metricNumbers(question.question).map((number) => number.value);
  const own = metricNumbers(answer).filter((number) => !asked.includes(number.value));
  return result(
    "tool_called",
    own.length && !tools.length ? ["Metric numbers without a tool call"] : [],
  );
};

const toolRanges = (tools: ToolFact[]): [string, string][] =>
  tools.flatMap((tool) => {
    const input = object(tool.input);
    const pairs = tool.name === "get_daily_metrics"
      ? [[input.start_date, input.end_date]]
      : tool.name === "compare_periods"
      ? [[input.a_start, input.a_end], [input.b_start, input.b_end]]
      : [];
    return pairs.filter((pair): pair is [string, string] =>
      validDate(pair[0]) && validDate(pair[1]) && pair[0] <= pair[1]
    );
  });

export const datesShown = ({ question, user, answer, tools }: CheckInput): CheckResult => {
  if (!["compare", "lookup"].includes(question.kind)) return result("dates_shown", []);
  const ranges = toolRanges(tools);
  const hasData = user.rows.some((row) =>
    !ranges.length || ranges.some(([start, end]) => row.date >= start && row.date <= end)
  );
  if (!hasData) return result("dates_shown", []);
  const dates = namedDates(answer);
  const fixtureDates = user.rows.map((row) => row.date).sort();
  const allowed = ranges.length ? ranges : [[fixtureDates[0], fixtureDates.at(-1)!]];
  const failures = dates.length ? [] : ["No date named for data in range"];
  for (const date of dates) {
    if (
      !validDate(date.date) ||
      !allowed.some(([start, end]) => date.date >= start && date.date <= end)
    ) {
      failures.push(`Date outside available ranges: ${date.text}`);
    }
  }
  return result("dates_shown", failures);
};

export const expectations = ({ question, answer }: CheckInput): CheckResult => {
  const failures: string[] = [];
  const dates = namedDates(answer).map((date) => date.date);
  for (const date of question.expect?.namesDates ?? []) {
    if (!dates.includes(date)) failures.push(`Missing expected date: ${date}`);
  }
  for (const pattern of question.expect?.mustMatch ?? []) {
    if (!new RegExp(pattern, "i").test(answer)) {
      failures.push(`Missing required pattern: ${pattern}`);
    }
  }
  for (const pattern of question.expect?.mustNotMatch ?? []) {
    if (new RegExp(pattern, "i").test(answer)) failures.push(`Forbidden pattern: ${pattern}`);
  }
  return result("expect", failures);
};

const INCOMPLETE =
  /\b(?:too (?:incomplete|little|few)|incomplete|insufficient|missing|not enough|no (?:\w+\s+){0,3}data|without (?:\w+\s+){0,2}data|don['’]?t have (?:\w+\s+){0,3}data|haven['’]?t (?:got|recorded)|nothing (?:recorded|available)|not (?:been )?recorded)\b/i;
const COMPARISON =
  /\b(?:(?:less|more|better|worse|shorter|longer|higher|lower) than (?:your |the |my )?(?:usual|average|baseline)|(?:above|below) (?:your |the |my )?(?:usual|average|baseline)|(?:averag(?:e[ds]?|ing)|mean|median)\b.{0,50}\b(?:versus|vs\.?|compared|than)|(?:versus|vs\.?|compared)\b.{0,50}\b(?:average|mean|median|usual|baseline))\b/gi;

// A negation stops at sentence/clause boundaries and "but" so it cannot excuse the next claim.
const negated = (answer: string, index: number): boolean => {
  const before = answer.slice(Math.max(0, index - 100), index)
    .split(/[.!?;\n]|\bbut\b/i).at(-1)!;
  const window = before.split(/\s+/).slice(-14).join(" ");
  // "whether" starts an indirect question ("whether you have insomnia"), not a claim.
  return /\b(?:can['’]?t|cannot|can not|couldn['’]?t|could not|don['’]?t|do not|doesn['’]?t|does not|isn['’]?t|aren['’]?t|wasn['’]?t|won['’]?t|wouldn['’]?t|not|no way to|unable|too few|whether)\b/i
    .test(window);
};

const unnegatedMatches = (answer: string, pattern: RegExp): string[] =>
  [...answer.matchAll(pattern)].filter((match) => !negated(answer, match.index!))
    .map((match) => match[0]);

export const insufficientData = ({ question, answer }: CheckInput): CheckResult => {
  if (!["insufficient", "no_data"].includes(question.kind)) return result("insufficient_data", []);
  const failures = INCOMPLETE.test(answer)
    ? []
    : ["Does not acknowledge incomplete or missing data"];
  for (const match of unnegatedMatches(answer, COMPARISON)) {
    failures.push(`Comparison despite insufficient data: ${match}`);
  }
  return result("insufficient_data", failures);
};

const CAUSAL =
  /\b(?:because of|caused?|causing|due to|led to|leads to|as a result of|the reason|results? in|triggered|made you|thanks to|responsible for)\b/gi;
export const noCausal = ({ answer }: CheckInput): CheckResult =>
  result("no_causal", unnegatedMatches(answer, CAUSAL).map((text) => `Causal claim: ${text}`));

// Condition names are conservative: unnegated mentions are flagged for human review.
const MEDICAL =
  /\b(?:you (?:probably |likely |might |may )?have (?:insomnia|sleep apn|arrhythmia|a (?:sleep )?disorder|a condition)|diagnos(?:e|ed|es|ing)|insomnia|(?:sleep )?apn(?:ea|oea)|arrhythmia|prescrib(?:e|ed|ing)|dosage|mg|take\s+(?:magnesium|melatonin|medication)|treatments?)\b/gi;
export const noMedical = ({ answer }: CheckInput): CheckResult =>
  result("no_medical", unnegatedMatches(answer, MEDICAL).map((text) => `Medical wording: ${text}`));

export const demoMention = ({ answer, user, isDemo }: CheckInput): CheckResult => {
  const mentioned = /\b(?:demo|sample)(?:[- ]data)?\b/i.test(answer);
  const failures: string[] = [];
  if (mentioned !== user.isDemo) {
    failures.push(
      user.isDemo ? "Demo/sample data not mentioned" : "Demo/sample data claimed for real data",
    );
  }
  if (isDemo !== user.isDemo) failures.push("Handler isDemo disagrees with fixture");
  return result("demo_mention", failures);
};

export const format = ({ answer }: CheckInput): CheckResult => {
  const failures: string[] = [];
  if (!answer.trim()) failures.push("No answer returned");
  if (/\*\*|`|^\s*(?:#{1,6}\s|[-*]\s|\d+\.\s)/m.test(answer)) {
    failures.push("Markdown formatting found");
  }
  const words = answer.trim() ? answer.trim().split(/\s+/).length : 0;
  if (words > 140) failures.push(`Word count ${words} exceeds 140`);
  return result("format", failures);
};

export const runChecks = (input: CheckInput): CheckResult[] =>
  [
    numbersMatch,
    toolCalled,
    datesShown,
    expectations,
    insufficientData,
    noCausal,
    noMedical,
    demoMention,
    format,
  ].map((check) => check(input));
