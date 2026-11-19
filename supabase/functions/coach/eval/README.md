# Coach eval

The runner calls the real coach handler with fixture data and grades answers with code rules. It
uses real Anthropic API calls only when `run.ts` is explicitly run. Normal Deno tests use scripted
responses and need no API key.

## Re-measure with Sonnet

Run on **your own computer**, in **Bash** from the repository root, with **Deno 2.x** installed
(local tests verified with 2.9.6), internet access for dependencies and Anthropic, and a key that
can use `claude-sonnet-5-5`. First set a low spend limit in the Anthropic Console; see
[SETUP.md](../../../../docs/SETUP.md#before-enabling-the-coach-set-an-anthropic-spend-limit). No
Supabase credentials or real health data are needed. This measurement has not been run here.

Copy and paste this one command. Enter the key at the hidden prompt; it exists only in memory and
the process environment, never in a file or shell history. Do not save it in `.env` or a script.

```bash
(
  read -r -s -p 'Anthropic API key (hidden): ' coach_api_key &&
  printf '\n' &&
  ANTHROPIC_API_KEY="$coach_api_key" COACH_MODEL=claude-sonnet-5-5 \
    deno run --config supabase/functions/deno.json \
      --allow-net=api.anthropic.com --allow-env --allow-read=docs/COACH_EVAL.md \
      --allow-write=docs/eval,docs/COACH_EVAL.md \
      supabase/functions/coach/eval/run.ts --repeat 3 --label sonnet
)
```

Budget for **26 questions × 3 repeats = 78 coach runs**, with up to 234 model message calls before
retries (which may add more). Each attempt uses at most 3 model calls and 1,500 output tokens per
call. The fixture database handles reservations locally without enforcing production daily caps.

The runner replaces `docs/eval/coach-results.json` and updates the generated section between the
eval markers in `docs/COACH_EVAL.md`, preserving text outside the markers. After reading the failed
answers, add a **Sonnet** row to that document's Results table with the timestamp, model, runtime
limits, pass count out of 78 and main failures. Keep historical Opus results labeled as such; the
new detailed results are already included automatically in the generated section.

See [COACH_EVAL.md](../../../../docs/COACH_EVAL.md#re-measure-with-sonnet) for scoring details and
options (`--repeat`, `--only`, `--label`).
