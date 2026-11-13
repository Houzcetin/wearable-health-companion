// Re-applies the current checks to saved answers, so runs made with older checks compare fairly.
// Usage (from supabase/functions): deno run --allow-read coach/eval/rescore.ts <results.json>...
import { CHECK_NAMES, runChecks } from "./checks.ts";
import { FIXTURE_USERS } from "./fixtures.ts";
import { QUESTIONS } from "./questions.ts";
import type { EvalResults } from "./run.ts";

for (const path of Deno.args) {
  const results: EvalResults = JSON.parse(await Deno.readTextFile(path));
  const counts = Object.fromEntries(CHECK_NAMES.map((name) => [name, 0]));
  let passed = 0;
  for (const run of results.runs) {
    const question = QUESTIONS.find((item) => item.id === run.questionId)!;
    const user = FIXTURE_USERS.find((item) => item.id === run.user)!;
    const checks = runChecks({
      question,
      user,
      answer: run.answer,
      tools: run.tools,
      isDemo: run.isDemo,
    });
    for (const check of checks) if (check.pass) counts[check.name]++;
    if (checks.every((check) => check.pass)) passed++;
    else {
      console.log(
        `  ${run.questionId} r${run.repeat}: ${
          checks.filter((check) => !check.pass).map((check) => `${check.name} (${check.detail})`)
            .join("; ")
        }`,
      );
    }
  }
  console.log(`${path} [${results.label}]: ${passed}/${results.runs.length} passed`);
  console.log(`  ${JSON.stringify(counts)}`);
}
