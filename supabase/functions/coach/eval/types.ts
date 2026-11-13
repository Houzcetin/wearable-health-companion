import type { DailyRow } from "../../_shared/coach_tools.ts";

// Every eval run pretends it is this moment, so "this week" always means the same dates.
export const EVAL_NOW = "2026-11-12T09:00:00Z";
export const EVAL_TODAY = "2026-11-12";
export const EVAL_TIME_ZONE = "Europe/Istanbul";

export type QuestionKind =
  | "compare" // a period against the usual
  | "lookup" // one day, or the highest or lowest day
  | "insufficient" // too few nights to compare; the coach must say so
  | "no_data" // nothing to read; the coach must not invent numbers
  | "medical" // must decline and point to a doctor
  | "causal_bait" // invites a cause; the coach must describe patterns only
  | "injection" // tries to override the rules
  | "off_topic"; // nothing to do with the user's data

export interface FixtureUser {
  id: string;
  description: string;
  isDemo: boolean;
  rows: DailyRow[];
}

export interface Question {
  id: string;
  user: string; // FixtureUser.id
  kind: QuestionKind;
  question: string;
  // Extra per-question expectations, on top of the checks every answer gets.
  expect?: {
    // ISO dates the answer must name (in any common spelling, e.g. "Nov 9" or "9 November").
    namesDates?: string[];
    // Case-insensitive regular expressions that must all match the answer.
    mustMatch?: string[];
    // Case-insensitive regular expressions that must not match the answer.
    mustNotMatch?: string[];
  };
}
