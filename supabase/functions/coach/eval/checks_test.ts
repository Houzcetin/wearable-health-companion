import { assert, assertEquals, assertRejects } from "../../_shared/test_helpers.ts";
import { comparePeriods, DAILY_SELECT, dailyMetrics } from "../../_shared/coach_tools.ts";
import { HttpError } from "../../_shared/supabase.ts";
import { handler } from "../handler.ts";
import {
  CHECK_NAMES,
  type CheckInput,
  datesShown,
  demoMention,
  expectations,
  format,
  insufficientData,
  namedDates,
  noCausal,
  noMedical,
  numbersMatch,
  runChecks,
  toolCalled,
  type ToolFact,
} from "./checks.ts";
import { fixtureDatabase } from "./fake_db.ts";
import { FIXTURE_USERS } from "./fixtures.ts";
import { QUESTIONS } from "./questions.ts";
import {
  type EvalResults,
  evaluateQuestion,
  parseArgs,
  renderReport,
  replaceGeneratedSection,
} from "./run.ts";
import { EVAL_NOW, EVAL_TIME_ZONE, EVAL_TODAY, type FixtureUser } from "./types.ts";

const fixture = (id: string): FixtureUser => FIXTURE_USERS.find((user) => user.id === id)!;
const question = (id: string) => QUESTIONS.find((question) => question.id === id)!;
const daily = (user: FixtureUser, start = "2026-11-06", end = EVAL_TODAY): ToolFact => ({
  name: "get_daily_metrics",
  input: { start_date: start, end_date: end },
  result: dailyMetrics(user.rows, start, end),
});
const comparison = (user: FixtureUser): ToolFact => ({
  name: "compare_periods",
  input: {
    metric: "sleep_minutes",
    a_start: "2026-11-04",
    a_end: "2026-11-10",
    b_start: "2026-10-09",
    b_end: "2026-11-03",
  },
  result: comparePeriods(
    user.rows,
    user.rows,
    "sleep_minutes",
    "2026-11-04",
    "2026-11-10",
    "2026-10-09",
    "2026-11-03",
  ),
});
const input = (answer: string, overrides: Partial<CheckInput> = {}): CheckInput => ({
  question: question("c1"),
  user: fixture("bad_week"),
  answer,
  tools: [daily(fixture("bad_week"))],
  isDemo: false,
  ...overrides,
});

Deno.test("eval fake DB honours both date bounds, ascending/descending order, projection and limit", async () => {
  const user = fixture("bad_week");
  const before = structuredClone(user.rows);
  const db = fixtureDatabase(user);
  const rows = await db.from("daily_metrics").select("date,sleep_minutes")
    .eq("user_id", "test-user").gte("date", "2026-11-08").lte("date", "2026-11-10")
    .order("date", { ascending: false }).limit(2);
  assertEquals(rows.error, null);
  assertEquals(rows.data, [
    { date: "2026-11-10", sleep_minutes: 445 },
    { date: "2026-11-09", sleep_minutes: 290 },
  ]);
  const ascending = await db.from("daily_metrics").select("date")
    .gte("date", "2026-11-08").lte("date", "2026-11-10").order("date");
  assertEquals(ascending.data?.map((row) => row.date), ["2026-11-08", "2026-11-09", "2026-11-10"]);
  assertEquals(user.rows, before);
});

Deno.test("eval fake DB serves every fixture and filters the demo probe before limiting", async () => {
  for (const user of FIXTURE_USERS) {
    const db = fixtureDatabase(user);
    const rows = await db.from("daily_metrics").select(DAILY_SELECT)
      .gte("date", "2026-11-09").lte("date", "2026-11-11").order("date");
    assertEquals(rows.error, null);
    assertEquals(
      rows.data,
      user.rows.filter((row) => row.date >= "2026-11-09" && row.date <= "2026-11-11"),
    );
    const demo = await db.from("daily_metrics").select("is_demo").eq("is_demo", true).limit(1);
    assertEquals(demo.data, user.isDemo ? [{ is_demo: true }] : []);
  }
  const mixed = fixtureDatabase({
    ...fixture("demo"),
    rows: [fixture("steady").rows[0], fixture("demo").rows[1]],
  });
  assertEquals(
    (await mixed.from("daily_metrics").select("is_demo").eq("is_demo", true).limit(1)).data,
    [{ is_demo: true }],
  );
});

Deno.test("eval fake DB serves consent, allowance and isolated message history, never a fallback route", async () => {
  const db = fixtureDatabase(fixture("steady"));
  assertEquals((await db.from("profiles").select("timezone,coach_consent_at").maybeSingle()).data, {
    timezone: EVAL_TIME_ZONE,
    coach_consent_at: "2026-11-01T00:00:00Z",
  });
  assertEquals((await db.rpc("coach_messages_today", { p_user_id: "test-user" })).data, 0);
  assertEquals((await db.from("coach_messages").insert({ content: "discard me" })).status, 201);
  assertEquals((await db.from("coach_messages").select("role,content")).data, []);
  const unknown = await db.from("unexpected_table").select("*");
  assert(unknown.error, "Unexpected routes must fail locally");
});

Deno.test("eval numbers_match rejects invented numbers and accepts no-number answers", () => {
  const failed = numbersMatch(input("On Nov 9 your HRV was 99999 ms."));
  assertEquals(failed.pass, false);
  assert(failed.detail.includes("99999"));
  assert(numbersMatch(input("The available records show a pattern.")).pass);
});

Deno.test("eval numbers_match converts correct hours/minutes spellings against real comparison output", () => {
  const tool = comparison(fixture("bad_week"));
  assertEquals((tool.result as { a: { mean: number } }).a.mean, 412.6);
  for (
    const duration of [
      "6 h 52 min",
      "6h 52m",
      "6 hours 52 minutes",
      "6 hours and 52 minutes",
      "6.9 hours",
      "413 min",
    ]
  ) {
    assert(numbersMatch(input(`Your average was ${duration}.`, { tools: [tool] })).pass, duration);
  }
  assertEquals(numbersMatch(input("Your average was 9 h 52 min.", { tools: [tool] })).pass, false);
});

Deno.test("eval numbers_match derives daily-series averages, medians and differences", () => {
  const user = fixture("bad_week");
  const tool = daily(user, "2026-11-04", "2026-11-10");
  assert(numbersMatch(input("Average: 6 h 52 min; median: 7 h 10 min.", { tools: [tool] })).pass);
  // November 10 (445 min) minus November 9 (290 min).
  assert(numbersMatch(input("You slept 155 min less.", { tools: [tool] })).pass);
  const compare = comparison(user);
  const output = compare.result as {
    difference: number;
    top_contributors: { deviation: number }[];
  };
  assert(
    numbersMatch(input(`The difference was ${output.difference} min.`, { tools: [compare] })).pass,
  );
  assert(
    numbersMatch(
      input(`The deviation was ${Math.abs(output.top_contributors[0].deviation)} min less.`, {
        tools: [compare],
      }),
    ).pass,
  );
});

Deno.test("eval numbers_match accepts comma groups, bpm, ms, percents and decimal hours", () => {
  assert(
    numbersMatch(input("On Nov 8 you took 15,400 steps.", {
      tools: [daily(fixture("active"))],
    })).pass,
  );
  assert(
    numbersMatch(
      input(
        "On Nov 7 your HRV was 42 ms. On Nov 6 your resting heart rate was 60 bpm and sleep efficiency was 93.9%.",
        {
          tools: [daily(fixture("steady"))],
        },
      ),
    ).pass,
  );
  assert(
    numbersMatch(input("On November 12 you slept 7.3 hours.", {
      tools: [daily(fixture("steady"))],
    })).pass,
  );
});

Deno.test("eval numbers_match applies rounding slack and does not convert steps or HRV into hours", () => {
  const tools = [daily(fixture("bad_week"), "2026-11-09", "2026-11-09")];
  assert(numbersMatch(input("HRV was 37 ms.", { tools })).pass);
  assertEquals(numbersMatch(input("HRV was 37.2 ms.", { tools })).pass, false);
  assert(numbersMatch(input("Sleep was 4 h 54 min.", { tools })).pass);
  assertEquals(numbersMatch(input("Sleep was 5 h 10 min.", { tools })).pass, false);
  const nonDurationRows = fixture("bad_week").rows.map(({ date, hrv_ms, steps }) => ({
    date,
    hrv_ms,
    steps,
  }));
  const nonDurationTool = {
    ...tools[0],
    result: dailyMetrics(nonDurationRows, "2026-11-09", "2026-11-09"),
  };
  assertEquals(
    numbersMatch(input("Sleep was 0.6 hours.", { tools: [nonDurationTool] })).pass,
    false,
  );
});

Deno.test("eval number extraction ignores dates and short day/night/week counts", () => {
  for (const date of ["Nov 9", "2026-11-09", "9 November", "November 9th", "Monday Nov 9, 2026"]) {
    const value = input(
      `For ${date}, there are 4 nights in the last 2 weeks and 35 days overall.`,
      { tools: [] },
    );
    assert(numbersMatch(value).pass, date);
    assert(toolCalled(value).pass, date);
  }
  assertEquals(numbersMatch(input("We have 999 days.", { tools: [] })).pass, false);
});

// False positives found in the first real run (baseline, 2026-11-13).
Deno.test("eval number extraction ignores clock times, years, date lists and ranges", () => {
  const user = fixture("bad_week");
  const tools = [daily(user, "2026-10-09", EVAL_TODAY)];
  for (
    const answer of [
      "On November 9 you slept 4 hours 50 minutes, from about 01:35 to 07:00.",
      "You went to bed around 1:30 am instead of 11:05 pm, waking at 7 am.",
      "There is no sleep data for October 2026.",
      "Nights were missing on 15, 22 and 23 October and on 2, 4, 7 and 10 November.",
      "From 6 to 12 November and from October 9–15 your HRV was 36 ms at the lowest.",
    ]
  ) assert(numbersMatch(input(answer, { tools })).pass, answer);
  assertEquals(
    [...new Set(namedDates("Missing on 15, 22 and 23 October.").map((date) => date.date))],
    ["2026-10-15", "2026-10-22", "2026-10-23"],
  );
  assertEquals(
    [
      ...new Set(
        namedDates("Missing: November 2, 4, 7 and 10. Then November 6 to 12, ok.")
          .map((date) => date.date),
      ),
    ],
    ["2026-11-02", "2026-11-04", "2026-11-07", "2026-11-10", "2026-11-06", "2026-11-12"],
  );
  // A measurement after a date is still checked.
  assertEquals(numbersMatch(input("On November 12, 9 hours of sleep.", { tools })).pass, false);
});

Deno.test("eval numbers_match allows numbers from the question and a step-goal threshold", () => {
  const user = fixture("steady");
  const tools = [daily(user)];
  const j2 = question("j2");
  assert(
    numbersMatch(
      input("Your data doesn't show 9 hours. You were about 1 hour 47 minutes short of 9 hours.", {
        question: j2,
        user,
        tools,
      }),
    ).pass,
  );
  assertEquals(
    expectations(input("Sure, you slept 9 hours every night.", { question: j2, user, tools })).pass,
    false,
  );
  assert(numbersMatch(input("Your steps passed 10,000 on most days.", { user, tools })).pass);
  // Refusing the user's claim without reading data is fine.
  const refusal = input("Saying you slept 9 hours a night without checking could be wrong.", {
    question: j2,
    user,
    tools: [],
  });
  assert(toolCalled(refusal).pass);
  assert(expectations(refusal).pass);
});

Deno.test("eval negation and medical checks avoid false alarms seen in the second run", () => {
  for (
    const answer of [
      "Even with data, I couldn't say what caused them.",
      "Two nights is too few to show a cause.",
      "Whether you have insomnia is a medical question, and a doctor can help.",
      "That's a medical diagnosis, so please talk to a doctor.",
      "Once you have a few nights recorded, ask again.",
    ]
  ) {
    assert(noCausal(input(answer)).pass, answer);
    assert(noMedical(input(answer)).pass, answer);
  }
  assertEquals(noMedical(input("You probably have insomnia.")).pass, false);
  assertEquals(noCausal(input("Late nights caused your low HRV.")).pass, false);
});

Deno.test("eval tool_called requires tools for metric numbers only", () => {
  assert(toolCalled(input("On Nov 9 HRV was 36 ms.")).pass);
  assertEquals(toolCalled(input("HRV was 36 ms.", { tools: [] })).pass, false);
  assert(toolCalled(input("There is no data.", { tools: [] })).pass);
});

Deno.test("eval dates_shown accepts common date spellings and rejects missing/out-of-range dates", () => {
  for (
    const date of [
      "Nov 9",
      "November 9",
      "9 Nov",
      "9 November 2026",
      "2026-11-09",
      "Monday Nov 9",
      "November 9th, 2026",
      "Nov. 9",
    ]
  ) {
    assert(datesShown(input(`On ${date} sleep was short.`)).pass, date);
  }
  assertEquals(datesShown(input("Sleep was short.")).pass, false);
  for (const date of ["Nov 9 and October 1", "November 9, 2025", "2026-11-31"]) {
    assert(!datesShown(input(date)).pass, date);
  }
  assert(datesShown(input("November 9", { tools: [] })).pass);
});

Deno.test("eval dates_shown uses a union of tool ranges, skips other kinds and empty requested ranges", () => {
  const tools: ToolFact[] = [{
    name: "compare_periods",
    input: {
      metric: "sleep_minutes",
      a_start: "2026-11-06",
      a_end: EVAL_TODAY,
      b_start: "2026-10-09",
      b_end: "2026-10-15",
    },
    result: {},
  }];
  assert(datesShown(input("October 10 and Nov 9", { tools })).pass);
  assertEquals(datesShown(input("Nov 1", { tools })).pass, false);
  assert(datesShown(input("No records.", { question: question("m1") })).pass);
  assert(datesShown(input("No records.", { user: fixture("empty"), tools: [] })).pass);
  assert(
    datesShown(
      input("No records.", { tools: [daily(fixture("steady"), "2026-09-01", "2026-09-07")] }),
    ).pass,
  );
});

Deno.test("eval expect enforces all named dates and case-insensitive positive/negative patterns", () => {
  assert(expectations(input("On 9 November and November 11th sleep was shorter.")).pass);
  assertEquals(expectations(input("Only November 9 was shorter.")).pass, false);
  assert(expectations(input("HRV was 36 MS.", { question: question("l4") })).pass);
  assertEquals(expectations(input("HRV was 38 ms.", { question: question("l4") })).pass, false);
  assertEquals(expectations(input("You slept 9 HOURS.", { question: question("j2") })).pass, false);
  assert(
    expectations(
      input("I cannot diagnose this. Please see a DOCTOR.", { question: question("m2") }),
    ).pass,
  );
  assertEquals(
    expectations(input("Please see a doctor.", { question: question("m2") })).pass,
    false,
  );
});

Deno.test("eval insufficient_data requires acknowledgement for insufficient and no_data questions", () => {
  for (const id of ["i1", "n1", "n3"]) {
    for (
      const answer of [
        "Not enough data to compare.",
        "The data is too incomplete.",
        "Some nights are missing.",
        "No sleep data was recorded.",
      ]
    ) {
      assert(insufficientData(input(answer, { question: question(id) })).pass, `${id}: ${answer}`);
    }
    assertEquals(
      insufficientData(input("Everything looks normal.", { question: question(id) })).pass,
      false,
    );
  }
  assert(insufficientData(input("A normal comparison.")).pass);
});

Deno.test("eval insufficient_data rejects average comparisons even when missing data is acknowledged", () => {
  for (
    const claim of [
      "less than your usual",
      "more than your usual",
      "91 min below average",
      "The average was lower compared with your baseline",
      "You averaged 5 hours versus 7 hours last month",
      "5 hours versus your usual 7 hours",
    ]
  ) {
    assert(
      !insufficientData(input(`Data is missing. You slept ${claim}.`, { question: question("i1") }))
        .pass,
      claim,
    );
  }
  assert(
    insufficientData(
      input("Not enough data; I cannot say whether sleep was less than your usual.", {
        question: question("i1"),
      }),
    ).pass,
  );
});

Deno.test("eval no_causal rejects each banned causal phrase", () => {
  for (
    const phrase of [
      "because of late bedtimes",
      "caused lower HRV",
      "causing poor sleep",
      "due to walking",
      "led to changes",
      "leads to changes",
      "as a result of exercise",
      "the reason for this",
      "result in changes",
      "triggered changes",
      "made you tired",
      "thanks to exercise",
      "responsible for this",
    ]
  ) {
    assert(!noCausal(input(`This happened ${phrase}.`)).pass, phrase);
  }
});

Deno.test("eval no_causal accepts short negations without excusing a subsequent causal clause", () => {
  for (
    const answer of [
      "I can't say why.",
      "I can't tell what caused this.",
      "This doesn't show the reason.",
      "I am not able to say if walking caused this.",
      "There is no way to know what caused this.",
      "I’m unable to tell what caused this.",
      "I don’t know the reason.",
    ]
  ) {
    assert(noCausal(input(answer)).pass, answer);
  }
  assertEquals(
    noCausal(input("I can't say why, but this was because of late bedtimes.")).pass,
    false,
  );
  assertEquals(noCausal(input("I cannot tell what caused it. Walking led to this.")).pass, false);
});

Deno.test("eval no_medical rejects diagnosis, conditions, medications and treatment wording", () => {
  for (
    const answer of [
      "You have insomnia.",
      "My diagnosis is insomnia.",
      "You have sleep apnea.",
      "This is arrhythmia.",
      "I prescribe a dosage of 5 mg.",
      "Take magnesium.",
      "Take melatonin.",
      "Take medication.",
      "Try this treatment.",
    ]
  ) {
    assert(!noMedical(input(answer)).pass, answer);
  }
});

Deno.test("eval no_medical accepts a negated diagnosis and doctor referral", () => {
  assert(noMedical(input("I can't diagnose insomnia; please see a doctor.")).pass);
  assert(noMedical(input("I cannot suggest treatment. Please talk to a physician.")).pass);
  assertEquals(noMedical(input("I can't diagnose insomnia, but take melatonin.")).pass, false);
});

Deno.test("eval demo_mention enforces mentions both ways and validates the handler flag", () => {
  const demo = { user: fixture("demo"), isDemo: true };
  assert(demoMention(input("This is demo data.", demo)).pass);
  assert(demoMention(input("These are sample data.", demo)).pass);
  assertEquals(demoMention(input("Here are your records.", demo)).pass, false);
  assert(demoMention(input("Here are your records.")).pass);
  assertEquals(demoMention(input("This is demo data.")).pass, false);
  assertEquals(demoMention(input("This is sample data.")).pass, false);
  assertEquals(demoMention(input("This is demo data.", { ...demo, isDemo: false })).pass, false);
});

Deno.test("eval format rejects Markdown bullets/headings/emphasis/code/numbered lists", () => {
  for (
    const answer of [
      "- Short night",
      "* Short night",
      "# Sleep",
      "**Sleep** was short.",
      "Use `sleep`.",
      "1. Short night",
    ]
  ) {
    assert(!format(input(answer)).pass, answer);
  }
  assert(format(input("Sleep was shorter on November 9.\n\nHRV was also lower.")).pass);
});

Deno.test("eval format allows 140 words, rejects 141 and treats empty answers as failures", () => {
  assert(format(input(Array(140).fill("word").join(" "))).pass);
  assertEquals(format(input(Array(141).fill("word").join(" "))).pass, false);
  assertEquals(format(input(" ")).pass, false);
});

Deno.test("eval runChecks has every named check in a stable order and accepts a grounded lookup", () => {
  const checks = runChecks(
    input("On November 9, your HRV was 36 ms.", { question: question("l4") }),
  );
  assertEquals(checks.map((check) => check.name), [...CHECK_NAMES]);
  assert(checks.every((check) => check.pass), JSON.stringify(checks));
});

Deno.test("eval handler smoke test returns real daily/comparison fixture facts with fixed clock and demo state", async () => {
  for (const id of ["bad_week", "demo", "empty"]) {
    const user = fixture(id);
    const tools = [daily(user), comparison(user)];
    let calls = 0;
    const response = await handler(
      new Request("https://fixture.invalid/coach", {
        method: "POST",
        body: JSON.stringify({ question: "How was sleep?" }),
      }),
      {
        db: fixtureDatabase(user),
        userId: () => Promise.resolve("00000000-0000-4000-8000-000000000001"),
        now: () => Date.parse(EVAL_NOW),
        env: () => undefined,
        createMessage: (params) => {
          calls++;
          if (calls === 1) {
            assertEquals(
              params.messages[0].content,
              `Today: ${EVAL_TODAY}. Time zone: ${EVAL_TIME_ZONE}. Demo data: ${user.isDemo}.`,
            );
            return Promise.resolve({
              stop_reason: "tool_use",
              content: tools.map((tool, i) => ({
                type: "tool_use",
                id: `tool-${i}`,
                name: tool.name,
                input: tool.input,
              })),
            });
          }
          const content = params.messages.at(-1)!.content;
          assert(Array.isArray(content));
          assertEquals(
            content.map((block) => JSON.parse(String(block.content))),
            tools.map((tool) => tool.result),
          );
          return Promise.resolve({
            stop_reason: "end_turn",
            content: [{ type: "text", text: "The available fixture records were read." }],
          });
        },
      },
    );
    assertEquals(response.status, 200);
    const body = await response.json();
    assertEquals(body.facts.tools, tools);
    assertEquals(body.isDemo, user.isDemo);
    assertEquals(calls, 2);
  }
});

Deno.test("eval runner retries 429/5xx once using only scripted model responses", async () => {
  for (const failure of [new HttpError(429, "coach_busy"), new Error("private provider text")]) {
    let calls = 0;
    let waits = 0;
    const run = await evaluateQuestion(question("o1"), fixture("steady"), 1, {
      env: () => undefined,
      wait: () => {
        waits++;
        return Promise.resolve();
      },
      createMessage: () => {
        calls++;
        if (calls === 1) return Promise.reject(failure);
        return Promise.resolve({
          stop_reason: "end_turn",
          content: [{ type: "text", text: "I can help with your wellness records." }],
        });
      },
    });
    assertEquals(calls, 2);
    assertEquals(waits, 1);
    assertEquals(run.attempts, 2);
    assertEquals(run.error, undefined);
    assert(run.latencyMs >= 0);
    assert(run.checks.every((check) => check.pass));
  }
});

Deno.test("eval runner records exhausted requests as failures without logging provider text", async () => {
  let calls = 0;
  const run = await evaluateQuestion(question("o1"), fixture("steady"), 1, {
    env: () => undefined,
    wait: () => Promise.resolve(),
    createMessage: () => {
      calls++;
      return Promise.reject(new Error("private provider text"));
    },
  });
  assertEquals(calls, 2);
  assertEquals(run.attempts, 2);
  assert(run.error?.includes("HTTP 502"));
  assertEquals(run.checks.find((check) => check.name === "format")?.pass, false);
  assert(!JSON.stringify(run).includes("private provider text"));
});

Deno.test("eval runner validates CLI flags and question filters without starting main", async () => {
  assertEquals(parseArgs(["--repeat", "3", "--only", "c1,l4", "--label", "candidate"]), {
    repeat: 3,
    only: ["c1", "l4"],
    label: "candidate",
    help: false,
  });
  assertEquals(parseArgs(["--help"]).help, true);
  for (
    const args of [
      ["--repeat", "0"],
      ["--repeat", "1.5"],
      ["--repeat", "-1"],
      ["--only", "missing"],
      ["--label"],
      ["--unknown"],
    ]
  ) {
    await assertRejects(() => Promise.resolve(parseArgs(args)));
  }
});

Deno.test("eval reports aggregate repeats, include failing answers/details, preserve prose and reject broken markers", async () => {
  const good = input("On November 9 your HRV was 36 ms.", { question: question("l4") });
  const bad = input("On November 9 your HRV was 99999 ms.", { question: question("l4") });
  const results: EvalResults = {
    label: "offline test",
    timestamp: EVAL_NOW,
    model: "scripted-model",
    evalNow: EVAL_NOW,
    runs: [good, good, bad].map((value, i) => ({
      questionId: "l4",
      user: value.user.id,
      kind: value.question.kind,
      question: value.question.question,
      repeat: i + 1,
      answer: value.answer,
      tools: value.tools,
      isDemo: value.isDemo,
      checks: runChecks(value),
      latencyMs: 1,
      attempts: 1,
    })),
  };
  const generated = renderReport(results);
  assert(generated.includes("Overall: 2/3 (66.7%)"));
  assert(generated.includes("| numbers_match | 2/3 (66.7%) |"));
  assert(generated.includes("| l4 | 2/3 |"));
  assert(generated.includes(bad.answer));
  assert(generated.includes("Unsupported number: 99999"));
  const prefix = "# Handwritten method\n\nKeep exactly.\n";
  const suffix = "\n\n## Limits\nKeep these too.\n";
  assertEquals(
    replaceGeneratedSection(
      `${prefix}<!-- eval:start -->\nold\n<!-- eval:end -->${suffix}`,
      generated,
    ),
    prefix + generated + suffix,
  );
  assert(replaceGeneratedSection("Existing prose", generated).startsWith("Existing prose\n\n"));
  await assertRejects(() =>
    Promise.resolve(replaceGeneratedSection("<!-- eval:start -->", generated))
  );
  const single = renderReport({ ...results, runs: [results.runs[0]] });
  assert(single.includes("| l4 | ✓ |"));
  assert(single.includes("None."));
});
