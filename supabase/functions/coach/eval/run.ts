// Manual entry point only. Importing helpers in tests never starts an evaluation.
import { handler } from "../handler.ts";
import type { CreateMessage } from "../types.ts";
import { CHECK_NAMES, type CheckResult, runChecks, type ToolFact } from "./checks.ts";
import { fixtureDatabase } from "./fake_db.ts";
import { FIXTURE_USERS } from "./fixtures.ts";
import { QUESTIONS } from "./questions.ts";
import { EVAL_NOW, type FixtureUser, type Question } from "./types.ts";

const USER_ID = "00000000-0000-4000-8000-000000000001";
const ROOT = new URL("../../../../", import.meta.url);
const REPORT = new URL("docs/COACH_EVAL.md", ROOT);
const RESULTS = new URL("docs/eval/coach-results.json", ROOT);
const START = "<!-- eval:start -->";
const END = "<!-- eval:end -->";

export interface Options {
  repeat: number;
  only: string[];
  label: string;
  help: boolean;
}

export const parseArgs = (args: string[]): Options => {
  const options: Options = { repeat: 1, only: [], label: "baseline", help: false };
  for (let i = 0; i < args.length; i++) {
    const flag = args[i];
    if (flag === "--help") {
      options.help = true;
      continue;
    }
    if (!["--repeat", "--only", "--label"].includes(flag)) throw new Error("Unknown eval option");
    const value = args[++i];
    if (!value || value.startsWith("--")) throw new Error("Missing eval option value");
    if (flag === "--repeat") {
      if (!/^\d+$/.test(value) || !Number.isSafeInteger(Number(value)) || Number(value) < 1) {
        throw new Error("Repeat must be a positive integer");
      }
      options.repeat = Number(value);
    } else if (flag === "--only") {
      options.only = [...new Set(value.split(","))];
      if (options.only.some((id) => !QUESTIONS.some((question) => question.id === id))) {
        throw new Error("Unknown question id in --only");
      }
    } else options.label = value;
  }
  return options;
};

export interface EvalRun {
  questionId: string;
  user: string;
  kind: Question["kind"];
  question: string;
  repeat: number;
  answer: string;
  tools: ToolFact[];
  isDemo: boolean;
  checks: CheckResult[];
  latencyMs: number;
  attempts: number;
  error?: string;
}

export interface EvalResults {
  label: string;
  timestamp: string;
  model: string;
  evalNow: string;
  runs: EvalRun[];
}

// The handler sanitizes upstream failures to 429/502 and does not expose Retry-After.
export const evaluateQuestion = async (
  question: Question,
  user: FixtureUser,
  repeat: number,
  deps: {
    createMessage: CreateMessage;
    env: (name: string) => string | undefined;
    wait?: () => Promise<void>;
  },
): Promise<EvalRun> => {
  const started = performance.now();
  let response: Response;
  let attempts = 0;
  do {
    attempts++;
    response = await handler(
      new Request("https://fixture.invalid/coach", {
        method: "POST",
        body: JSON.stringify({ question: question.question }),
      }),
      {
        db: fixtureDatabase(user),
        userId: () => Promise.resolve(USER_ID),
        now: () => Date.parse(EVAL_NOW),
        env: deps.env,
        createMessage: deps.createMessage,
      },
    );
    if (attempts === 2 || (response.status !== 429 && response.status < 500)) break;
    await response.body?.cancel();
    await (deps.wait ?? (() => new Promise<void>((resolve) => setTimeout(resolve, 1000))))();
  } while (true);
  let answer = "";
  let tools: ToolFact[] = [];
  let isDemo = user.isDemo;
  if (response.ok) {
    const body = await response.json();
    if (
      typeof body.answer !== "string" || !Array.isArray(body.facts?.tools) ||
      typeof body.isDemo !== "boolean"
    ) throw new Error("Invalid handler response");
    answer = body.answer;
    tools = body.facts.tools;
    isDemo = body.isDemo;
  } else await response.body?.cancel();
  return {
    questionId: question.id,
    user: user.id,
    kind: question.kind,
    question: question.question,
    repeat,
    answer,
    tools,
    isDemo,
    checks: runChecks({ question, user, answer, tools, isDemo }),
    latencyMs: Math.round(performance.now() - started),
    attempts,
    ...(!response.ok
      ? { error: `Handler returned HTTP ${response.status} after ${attempts} attempts` }
      : {}),
  };
};

const escapeCell = (value: string) => value.replaceAll("|", "\\|").replace(/[\r\n]/g, " ");
const fraction = (count: number, total: number) =>
  `${count}/${total} (${total ? (100 * count / total).toFixed(1) : "0.0"}%)`;
const passed = (run: EvalRun) => run.checks.every((check) => check.pass);
const fenced = (text: string) => {
  const longest = Math.max(2, ...[...text.matchAll(/`+/g)].map((match) => match[0].length));
  const fence = "`".repeat(longest + 1);
  return `${fence}text\n${text}\n${fence}`;
};

export const renderReport = (results: EvalResults): string => {
  const { runs } = results;
  const lines = [
    START,
    "## Latest evaluation",
    "",
    `Label: ${escapeCell(results.label)}  `,
    `Timestamp: ${results.timestamp}  `,
    `Model requested: ${escapeCell(results.model)}  `,
    `Fixture clock: ${results.evalNow}`,
    "",
    `Overall: ${
      fraction(runs.filter(passed).length, runs.length)
    } question-runs passed every check.`,
    "",
    "| Check | Passed |",
    "| --- | --- |",
    ...CHECK_NAMES.map((name) =>
      `| ${name} | ${
        fraction(
          runs.filter((run) => run.checks.some((check) => check.name === name && check.pass))
            .length,
          runs.length,
        )
      } |`
    ),
    "",
    "## Questions by check",
    "",
    "For repeats, each cell is passed/total. An overall pass requires every check to pass.",
    "",
    `| Question | ${CHECK_NAMES.join(" | ")} | Overall |`,
    `| --- | ${CHECK_NAMES.map(() => "---").join(" | ")} | --- |`,
  ];
  for (const id of new Set(runs.map((run) => run.questionId))) {
    const group = runs.filter((run) => run.questionId === id);
    const cell = (count: number) =>
      group.length === 1 ? (count === 1 ? "✓" : "✗") : `${count}/${group.length}`;
    lines.push(
      `| ${escapeCell(id)} | ${
        CHECK_NAMES.map((name) =>
          cell(
            group.filter((run) => run.checks.some((check) => check.name === name && check.pass))
              .length,
          )
        ).join(" | ")
      } | ${cell(group.filter(passed).length)} |`,
    );
  }
  lines.push("", "## Failures", "");
  if (runs.every(passed)) lines.push("None.", "");
  for (const run of runs.filter((run) => !passed(run))) {
    lines.push(
      `### ${run.questionId}, repeat ${run.repeat} (${run.user})`,
      "",
      fenced(run.question),
      "",
      "Answer:",
      "",
      fenced(run.answer || "[No answer returned]"),
      "",
      ...(run.error ? [run.error, ""] : []),
      ...run.checks.filter((check) => !check.pass).map((check) =>
        `- ${check.name}: ${escapeCell(check.detail)}`
      ),
      "",
    );
  }
  lines.push(END);
  return lines.join("\n");
};

export const replaceGeneratedSection = (existing: string, generated: string): string => {
  const start = existing.indexOf(START);
  const end = existing.lastIndexOf(END);
  if (start === -1 && end === -1) {
    return `${existing}${existing.endsWith("\n") ? "\n" : "\n\n"}${generated}\n`;
  }
  if (start === -1 || end < start) throw new Error("Unpaired eval markers in report");
  return existing.slice(0, start) + generated + existing.slice(end + END.length);
};

const main = async () => {
  const options = parseArgs(Deno.args);
  if (options.help) {
    console.log(
      "Coach eval: [--repeat N] [--only c1,l4] [--label baseline]. See docs/COACH_EVAL.md.",
    );
    return;
  }
  if (!Deno.env.get("ANTHROPIC_API_KEY")) throw new Error("ANTHROPIC_API_KEY is required");
  const model = Deno.env.get("COACH_MODEL") || "claude-opus-5-5";
  const { createMessage } = await import("../anthropic.ts");
  const results: EvalResults = {
    label: options.label,
    timestamp: new Date().toISOString(),
    model,
    evalNow: EVAL_NOW,
    runs: [],
  };
  const questions = QUESTIONS.filter((question) =>
    !options.only.length || options.only.includes(question.id)
  );
  for (const question of questions) {
    const user = FIXTURE_USERS.find((user) => user.id === question.user);
    if (!user) throw new Error("Question references an unknown fixture");
    for (let repeat = 1; repeat <= options.repeat; repeat++) {
      const run = await evaluateQuestion(question, user, repeat, {
        createMessage,
        env: Deno.env.get,
      });
      results.runs.push(run);
      console.log(
        `${question.id} ${repeat}/${options.repeat}: ${
          passed(run) ? "pass" : "fail"
        } (${run.latencyMs} ms)`,
      );
    }
  }
  let existing = "# Coach evaluation\n";
  try {
    existing = await Deno.readTextFile(REPORT);
  } catch (error) {
    if (!(error instanceof Deno.errors.NotFound)) throw error;
  }
  const report = replaceGeneratedSection(existing, renderReport(results));
  await Deno.mkdir(new URL("docs/eval/", ROOT), { recursive: true });
  await Deno.writeTextFile(RESULTS, JSON.stringify(results, null, 2) + "\n");
  await Deno.writeTextFile(REPORT, report);
  console.log(
    `Wrote docs/eval/coach-results.json and docs/COACH_EVAL.md (${results.runs.length} runs).`,
  );
};

if (import.meta.main) {
  try {
    await main();
  } catch {
    // Raw exceptions can carry provider text or request headers. Never print them.
    console.error(
      "Coach evaluation crashed. Check options, API configuration, permissions, and report markers.",
    );
    Deno.exitCode = 1;
  }
}
