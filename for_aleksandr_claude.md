# Answers from Oğuz for the progress report

## 1. Did the Stage 2 interviews happen?

**No.** We did not run the Stage 2 interviews. Please say so honestly in the report and the deck.

- **What was planned.** `docs/PLAN.md` planned 5+ interviews with wearable users. Each interview would record what they check first in the morning and time that task in the official app, as the baseline for the 10-second target.
- **What happened.** We prioritised building the MVP. There are no interview notes.
- **Suggested wording for the report:** "Stage 2 interviews were planned but postponed. We will run them together with the Stage 7 five-user test, which already times the official app and our app side by side (`docs/USER_TEST_PROTOCOL.md`). Until then, *sleep leads the summary* is a design assumption, not a user finding."
- **Deck fix.** Slide 2 shows "Know your users: Done". Please change it to **"Postponed"**, in grey or amber, not green. The headline "Stages 1–6 built" can stay if you add "(Stage 2 postponed)".

## 2. Three real prompts

These are real prompts from Oğuz's orchestration session. Originals are in Turkish; the English versions are our translations.

### A. Oğuz → the orchestrator Claude session: split testing into its own session

Original:
> abi bune testi de mi sen yapıyorsun testi de başka bir subagenta ver
>
> tamam bir daha bunun olmaması için diğer bi session daha açalım o codexle iletişime geçsin sen sadece bana durumları haberdar et

Translation:
> Wait, are you doing the testing yourself too? Give the testing to another agent.
>
> OK, so this doesn't happen again, let's open another session that talks to Codex; you just keep me updated on the status.

- **Why it mattered.** The same session was writing code and checking its own work. Oğuz asked to separate the roles.
- **Outcome.** The four-role setup on slide 8: an Orchestrator, a Codex runner (coding through OpenAI Codex), a UI/UX session and a QA session. From then on, the builder never approved its own work.

### B. Orchestrator → QA session: setup prompt (excerpt)

Original (excerpt):
> Kod YAZMAZSIN, düzeltme yapmazsın, commit/push/PR yapmazsın. İşin: dalları çekmek, birleşimleri denemek, test/analiz çalıştırmak, diff'leri gözden geçirmek ve bulguları raporlamak.
> Deneme birleşimlerini her zaman scratchpad'de ayrı bir `git worktree` içinde yap […]
> Bulduğun bir hatayı düzeltmeye çalışma; dosya:satır, hata çıktısı ve önerilen düzeltmeyle raporla.
> Kontrol listesi (her doğrulamada): 1. flutter analyze […] 2. flutter test […] 3. supabase/ değiştiyse deno test […] 4. Diff incelemesi: proje kuralları ihlali var mı? […] 5. Rapor formatı: test edilen dal(lar) + SHA'lar, sonuç tablosu, çakışmalar, kural ihlalleri, bulgular (önem sırasıyla), "gerçek cihazda doğrulanmalı" notları.

Translation:
> You do NOT write code, you do not fix things, you do not commit, push or open PRs. Your job: pull branches, try merges, run tests and analysis, review diffs and report findings.
> Always do trial merges in a separate `git worktree` […]
> Don't try to fix a bug you find; report it with file:line, the error output and a suggested fix.
> Checklist (every verification): 1. flutter analyze […] 2. flutter test […] 3. if supabase/ changed, deno test […] 4. Diff review: any project-rule violations? […] 5. Report format: branches and SHAs tested, results table, conflicts, rule violations, findings by severity, and "verify on a real device" notes.

- **Why it worked.** It gave the session hard rules, a fixed checklist and a fixed report format.
- **Outcome.**
  - The rule "QA reports; it never edits code".
  - The security review on slide 7, where QA attacked a real Postgres.
  - QA also deliberately broke our checks (mutation tests) to prove the tests catch the break.

### C. Orchestrator → Codex runner: task for the web bug (excerpt)

Original (excerpt):
> KÖK NEDEN (yalnızca web/dart2js): JS'te int kaydırma 32 bit → 1<<32 ve 1<<53 = 0.
> - domain/auto_workout_detector.dart:333 `steps: (... ).clamp(0, 1 << 53)` → web'de steps hep 0. Düzelt: `math.max(0, _countAt(at) - _countAt(_startedAt!))`.
> - ui/workout_sheets.dart:10 `duration.inSeconds.clamp(0, 1 << 32)` → web'de süre hep "0:00". Düzelt: `math.max(0, duration.inSeconds)`.
> TESTLER: 1a) lib/**/*.dart içinde `<<\s*(3[2-9]|[4-9]\d)` […] kalıbını yasaklayan statik test. 1b) workout testlerini Chrome'da da koş […] — düzeltmeden önce kırıldığını, sonra geçtiğini raporla.

Translation:
> ROOT CAUSE (web/dart2js only): integer shifts in JS are 32-bit, so 1<<32 and 1<<53 become 0.
> - domain/auto_workout_detector.dart:333 `clamp(0, 1 << 53)` makes steps always 0 on the web. Fix: `math.max(0, …)`.
> - ui/workout_sheets.dart:10 `clamp(0, 1 << 32)` makes the duration always "0:00" on the web. Fix: `math.max(0, duration.inSeconds)`.
> TESTS: 1a) a static test that bans this shift pattern in lib/. 1b) also run the workout tests in Chrome, and report that they fail before the fix and pass after it.

- **Why it worked.**
  - QA found and proved the root cause first, with `dart compile js` and node.
  - The coding task then named the exact file and line, the exact fix, and tests that must fail before and pass after.
- **Outcome.**
  - The before/after on slide 9: "0:00 · 0 steps" became "12:00 · 1197".
  - A permanent Chrome test job in CI.

## 3. Small deck consistency notes

- **Table count.** Slide 5 says **19 tables**; slide 7 says **18 / 18 tables**. Use one number on both slides, for example "19 / 19 tables" if the rate-limit table is counted.
- **Stage 2.** Slide 2 marks Stage 2 as Done. Change it as in section 1.
