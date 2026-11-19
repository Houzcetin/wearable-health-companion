# Handoff

This document is for the next developer. It says what is on `main`, what is still in review, how to run and test the project, where things are, what is planned, and the decisions and traps you need to know. Facts were checked against the repository at `main` (72c4af5, after PR #20) and the open branches. Test counts are from local runs and may drift; CI is the source of truth.

Other documents: [PLAN.md](PLAN.md) (scope and course stages), [ARCHITECTURE.md](ARCHITECTURE.md) (diagrams and data flows), [TECHNICAL_REPORT.md](TECHNICAL_REPORT.md) (final report, risks), [SETUP.md](SETUP.md) (consoles and secrets), [COST_REPORT.md](COST_REPORT.md) (cost skeleton), [COACH_EVAL.md](COACH_EVAL.md), [API_NOTES.md](API_NOTES.md), [USER_GUIDE.md](USER_GUIDE.md), [IPHONE_TEST_CHECKLIST.md](IPHONE_TEST_CHECKLIST.md), [USER_TEST_PROTOCOL.md](USER_TEST_PROTOCOL.md).

## 1. Where things stand

Base: `origin/main` at `253ca6e` (merge of PR #23, after PRs #19, #20 and #21). Facts were checked against the repository at that commit and the open branches. Test counts are from local runs and may drift; CI is the source of truth.

### On `main` and working

| Area | State |
|---|---|
| Sign-in, separate health consent | Done in code. iOS sign-in is not yet verified on a device (SETUP.md). |
| Google Health connection and sync (Sync now, 15-minute cron, webhooks, backfill) | Done in code. Real-account behaviour is unverified: 13 `UNVERIFIED` markers remain. |
| Today: lead sentence, three cards, usual ranges | Done. |
| Trends: week and month, days outside the usual range | Done. |
| Coach: tools, consent, limits, Numbers used | Done. Cost limits merged with PR #23: default model Sonnet, `max_tokens` 1500, at most 3 model calls, atomic reservation with per-user and global 24-hour limits, and limit errors show a clear message without Retry. The 70 of 78 evaluation result (COACH_EVAL.md) was measured with the earlier model and prompt; re-run it (section 4f). |
| Export and delete (health data, account) | Done. Export scope is partial (backlog c). |
| Workout detection: live prompts, notifications, iPhone history suggestions | Done in code. iPhone path not verified on a device. Android has live detection only. |
| Database security hardening (PR #19) | Merged. Migration `20261119000000_security_hardening.sql`: profile timezones are normalised (section 6), sync claims are rate limited per user, privileges revoked, CHECK constraints added. |
| Demo mode (PR #20) and demo polish (PR #21) | Merged. |
| CI: Flutter analyze and tests, Chrome workout tests, Deno tests (PR #17) | Merged. Actions are pinned to version tags, not SHAs. |
| Docs: user guide, technical report, architecture, cost skeleton, checklists | Done. |

### Open PRs and branches

| Item | Branch | State | Notes |
|---|---|---|---|
| Tab re-tap fix | `claude/tab-retap-fix` | **No PR yet, not merged.** | Re-tapping the selected tab no longer resets its stack; Today scrolls to the top instead. Summaries are cleared when their sheet closes. The root cause of the reported "Walk summary" re-opening was **not reproduced**; the regression tests pass without the change too. Reproduce it before you rely on this fix. |

Other remote branches (`claude/auto-detect-workouts`, `claude/workouts-background`, `claude/workout-sync-*`, `claude/delete-cleanup-polish`, `claude/fix-sim-summary`, `claude/ios-google-signin-config`, `claude/peaceful-hawking-y65kgu`, `claude/readme-status`, `claude/ci-workflow`, `claude/demo-mode`, `claude/demo-polish`, `claude/security-hardening-db`) have been merged into `main` as earlier PRs. Check with `git log origin/main --oneline` before deleting any of them.

### Planned but not started

Everything in section 4 that is not in PR #23. The optional game layer (points, streaks, friends, challenges) is not built; its tables exist with RLS but no code uses them.

## 2. Quick start

### Demo mode (no backend, no device)

```sh
cd app
flutter pub get
flutter run -d chrome --dart-define=DEMO_MODE=true
```

For a release web build use `flutter build web --dart-define=DEMO_MODE=true --release` (output in `app/build/web`). Demo mode never contacts a backend, even when `SUPABASE_*` values are defined.

### With a real backend

1. Create the local files, which are git-ignored: `.env` (server secrets, see `.env.example`) and `.env.json` (public app settings).
2. Create `app/ios/Flutter/Google.xcconfig` from `Google.xcconfig.example` if you build for iOS.
3. Apply the migrations to your Supabase project (section 4g) and set the function secrets (SETUP.md, "Function secrets").
4. Run:

```sh
cd app
flutter run --dart-define-from-file=../.env.json
```

Without `.env.json` the app runs as an offline shell. Consoles, project IDs and the Google OAuth clients are in [SETUP.md](SETUP.md).

### Tests

| What | Command | Notes |
|---|---|---|
| Flutter (VM) | `cd app && flutter test` | About 373 tests on `main`; 12 screenshot tests are skipped unless `SCREENSHOTS=1 flutter test --tags screenshots test/screenshots` is used. |
| Workout tests on Chrome | `cd app && CHROME_EXECUTABLE=<chrome> flutter test --platform chrome test/workout_widgets_test.dart test/auto_workout_detector_test.dart` | Same command as CI. |
| Static analysis | `cd app && flutter analyze --no-fatal-infos` | No errors or warnings expected; infos about SDK deprecations remain. |
| Edge Functions (Deno) | `deno test --config supabase/functions/deno.json supabase/functions`, and the `_shared` command in `supabase/functions/README.md` | About 94 `Deno.test` calls on `main` (a grep count; parameterised cases add more). Deno was not available in the authoring workspace; CI runs it. Type checks: see the same README. |
| Coach evaluation | see COACH_EVAL.md, "How to run it again" | Makes real Claude API calls and needs `ANTHROPIC_API_KEY`. Run it on your own machine. |
| iPhone | [IPHONE_TEST_CHECKLIST.md](IPHONE_TEST_CHECKLIST.md) | Needs a Mac and Xcode. Run `RunnerTests` with ⌘U. |

CI (`.github/workflows/ci.yml`) runs the Flutter analysis and tests, the Chrome workout tests and the Deno tests on every pull request and push to `main`. It uses no secrets.

## 3. Repository map

```
app/                          Flutter app
  lib/core/                   env, router, theme, shared widgets, demo/ (demo mode)
  lib/data/                   auth, profile, health, coach repositories and providers
  lib/features/
    auth/ today/ trends/ coach/ settings/   the four tabs and onboarding
    play/                     placeholder (not in the tab bar)
    workouts/                 detector, sources, pending queue, history review, notifications, UI
  test/                       widget, domain, repository and golden tests; test/screenshots (on demand)
  ios/                        Runner (Swift: CoreMotion history, BGAppRefreshTask), RunnerTests, Flutter/*.xcconfig
  web/                        web shell (added for demo mode)
supabase/
  migrations/                 SQL, applied in filename order (section 4g)
  functions/                  Edge Functions, each with a handler and tests
    _shared/                  common code: Google, webhook signature, queue, worker, coach tools, fixtures
    coach/                    coach handler, Anthropic client, eval runner (coach/eval/)
    sync-worker/ health-webhook/ health-oauth-start/ health-oauth-callback/
    export-data/ delete-account/
  config.toml                 auth and function settings (verify_jwt is off; each handler checks its own caller)
docs/                         documents above; screenshots/ (light and dark, and demo web); eval/ (coach run results)
.github/workflows/ci.yml      CI
.env.example                  every variable name, no values
```

## 4. Backlog

Priority order. Each item lists what, why, where, and when it is done.

**(a) Coach cost limits: DONE (PR #23, merged).** *What:* Sonnet default (`COACH_MODEL`), `max_tokens` 1500, at most 3 model calls, an atomic `reserve_coach_question` reservation with per-user and global (`COACH_GLOBAL_DAILY_LIMIT`) limits over a rolling 24 hours, and clear limit messages without Retry. *Where:* `supabase/functions/coach/handler.ts`, migration `20261119020000_coach_cost_limits.sql`, `app/lib/features/coach/coach_screen.dart`. *Remaining:* re-run the evaluation with the new model (item f) and apply the migration to the live project (item g).


**(b) Mobile secure storage.** *What:* keep the Supabase session in the Keychain (iOS) and Keystore (Android), set `android:allowBackup="false"` (the manifest does not set it today, so Android backups are on), exclude the local workout queue from iOS backups, and store the pending queue (`workouts.pending.v1.<user id>` in SharedPreferences) in protected storage. *Why:* session tokens and health-adjacent data are plain text on the device and can be copied by backups. *Where:* `app/android/app/src/main/AndroidManifest.xml`, `app/lib/features/workouts/data/pending_workout_queue.dart`, the Supabase client initialisation in `app/lib/main.dart`, iOS Runner settings. *Done when:* a device backup does not contain the session or the queue, and sign-out still clears both.

**(c) Export scope.** *What:* add `weekly_insights`, `summary_feedback`, `point_events`, `tasks`, `characters`, `streaks`, `friendships`, `challenges`, `challenge_members`, `friend_invites` to the export. *Why:* the export is supposed to cover the user's data, and today it omits these. *Where:* `supabase/functions/export-data/handler.ts` (the `rows(...)` calls) and `handler_test.ts`. *Done when:* the test lists every user-owned table. **Deletion does not change**: the team decided that "Delete health data" keeps derived game data (see section 5).

**(d) Simulator polish.** *What:* manual session end is not clean; extend the prompt durations in the simulator 20×; add the web steps to `app/lib/features/workouts/README.md`; extend the shift-prohibition test (`app/test/web_int_safety_test.dart`) to cover the `0x` pattern; add a Run Script for an empty Google ID in iOS Release. *Why:* rough edges found in QA. *Done when:* the simulator flow is covered by the Chrome tests and the README steps have been tried.

**(e) iPhone verification.** *What:* run [IPHONE_TEST_CHECKLIST.md](IPHONE_TEST_CHECKLIST.md) on a device; fill in `app/ios/Flutter/Google.xcconfig` from the example (both IDs from the same iOS client). *Why:* the Swift code, background refresh, notifications and iOS sign-in have never run on a device. *Done when:* every box is ticked or the failures are listed as issues.

**(f) Coach eval with Sonnet.** *What:* after (a), re-run the evaluation on your own machine and record the result. *Why:* the 90% result is for the current model only. *Where:* COACH_EVAL.md ("How to run it again"), `docs/eval/`. *Done when:* the results table has a new row and the failures are classified.

**(g) Apply the migrations to the live project.** *What:* run these in order, by filename (the first five are on `main`):

1. `20261106000000_init.sql`
2. `20261112000000_health_connect.sql`
3. `20261113000000_stage5.sql`
4. `20261116000000_workouts.sql`
5. `20261116010000_workout_bounds.sql`
6. `20261119000000_security_hardening.sql` (merged with PR #19; apply it now if it is not yet on the live project)
7. `20261119020000_coach_cost_limits.sql` (only with PR #23, after item 6)

*Why:* the live project must match the code. *How to verify:* `supabase db push` (or the SQL editor), then check RLS is enabled on every table, that `anon` and `authenticated` cannot TRUNCATE, and that `pg_cron` runs `scheduled-sync` every 15 minutes. *Done when:* those checks pass and the results are noted in SETUP.md.

**(h) Spend limits.** *What:* set and record the limits: the Anthropic console spend limit, the Supabase spend cap and budget alert, and a Google Cloud budget alert. *Why:* there is no global ceiling in code yet. *Where:* COST_REPORT.md, section 6 checklist. *Done when:* each limit is set and the screenshot or setting is recorded.

**(i) Stage 7 beta and consent text.** *What:* fill in the placeholders in `USER_TEST_PROTOCOL.md` (controller, university, retention period), have the consent text reviewed (KVKK), run the five sessions, and fill in the results tables. Also fill in the cost figures in `COST_REPORT.md`. *Done when:* the results table is complete and the top three problems have fixes.

**(j) No Fitbit Air access.** *What:* we have no device, so the team relies on synthetic data and demo mode. *Why:* Google Health results on a real account are untested. *Where:* PLAN.md, section "To verify". *Done when:* a tester with a device connects and the last seven days match the official app; until then, use demo mode for demonstrations and say so.

## 5. Decisions already made

- **Records are open.** The orchestration notes say "kayıtlar açık". Confirm with the team what this covers before you act on it.
- **The coach uses Sonnet as the default** (backlog a, done in PR #23).
- **"Delete health data" does not delete derived game data.** Points, streaks and similar rows stay. The export is being extended so the user can see them (backlog c).
- **The coach evaluation is run on the team member's own machine**, because it needs their Anthropic key.
- **CI is in place** (PR #17). A PR is merged after CI is green and the review is done.
- **Workflow:** each task goes on its own branch, then CI, then PR, then merge. Commit messages end with the Co-Authored-By line used in this repository.

## 6. Gotchas

- **`flutter pub get`, `flutter test` and `flutter build` rewrite files.** `app/analysis_options.yaml` gets an "exclude build" block, and `pubspec.lock` can change when the tool version differs. `.metadata` can change too. Revert these before you commit (`git checkout app/analysis_options.yaml app/pubspec.lock`). Do not commit them.
- **`web/` is part of the repository now.** It came from `flutter create . --platforms web`. If it is missing, recreate it with that command and check that `index.html` and `manifest.json` still carry the app's title.
- **Dart on the web uses JavaScript numbers.** Bitwise operations on 32-bit values truncate silently; shifts of 32 bits or more give zero. Use arithmetic (`* 4294967296`), not shifts. `app/test/web_int_safety_test.dart` scans `lib/` for this. The notification timeout uses `1 << 31`, which is allowed.
- **Deno may be missing locally.** The Edge Function tests were not run in the authoring workspace because Deno is not installed there. If you have no Deno, rely on the CI job and do not assume the Edge Function tests pass.
- **`Google.xcconfig` is git-ignored.** Release and Profile include it with `#include?`, so a missing file does not break the build but iOS Google sign-in fails until the values are set.
- **Timezones are normalised, not rejected.** The trigger in `20261119000000_security_hardening.sql` maps old zone names to current ones (for example `Europe/Kiev` to `Europe/Kyiv`, `Asia/Calcutta` to `Asia/Kolkata`, `Asia/Saigon` to `Asia/Ho_Chi_Minh`, `US/*` to their current names). Unknown, null, over 64 characters or malformed values become `UTC`. Re-check the alias map against the live project's tzdata before you rely on it: Supabase's PostgreSQL build may differ from the local one.
- **Migrations with `NOT VALID`.** `20261116010000_workout_bounds.sql` adds CHECK constraints with `NOT VALID` (new rows are checked, old ones are not) and then `VALIDATE`s them. `VALIDATE` scans the table and fails if an existing row breaks the rule, so look at the data first on a large table.
- **Action tags in CI are version tags.** `ci.yml` pins actions by tag. For full pinning, replace each tag with its commit SHA (the comment at the top of the file says how).
- **Google Health wire shapes are unverified.** There are 13 `UNVERIFIED` markers in code (grep for `UNVERIFIED`); SETUP.md lists the wire-shape ones. Do not treat the mappings as proven until a real account has been read.
- **iPhone background behaviour is best effort.** iOS decides when `BGAppRefreshTask` runs. The app also checks motion history on resume, so a missed reminder does not lose a workout.
- **Workout times differ on purpose.** A running workout shows mm:ss; a finished one shows "30 min" (see `workout_today_card.dart`).
- **Bike rides have no distance or pace.** This is intentional and shown in the UI.

## 7. QA notes for the next maintainer

Database changes are tested against real PostgreSQL 16 (16.15 was used), not only by reading the SQL. Create a scratch cluster with initdb and start it on a spare port with a Unix socket in /var/tmp. Create a database, load the Supabase stand-ins (auth.users with auth.uid() reading request.jwt.claim.sub, vault.secrets with create_secret/update_secret, cron.schedule/unschedule, net.http_post, and the anon/authenticated/service_role roles). Then apply every file in supabase/migrations in filename order. pg_net and pg_cron are not available in a plain cluster, so strip their two create-extension lines first; this changes nothing else. Run supabase/tests/security_hardening.sql, sync_worker.sql and sync_worker_concurrency.py as supabase/tests/README.md describes. For a probe, connect with SET ROLE authenticated and set request.jwt.claims to a user id, then try the cross-user, consent, TRUNCATE and privilege cases; read results with has_table_privilege and pg_proc.proacl rather than assuming. Mutation testing: copy the migration, apply one deliberate break (remove a consent check, drop a revoke, change an interval, shorten an invite code, drop a CHECK, disable a trigger, remove a user filter), and confirm that the suite fails. Use sed patterns that are verified to match the line, and check that the mutant applied (grep it) before trusting a pass; one of our sed runs silently did not apply a mutant and looked like a pass. Stop the cluster and delete its data directory afterwards.

Known gaps: Vault encryption, pg_cron scheduling and pg_net HTTP delivery are not exercised (the stubs replace them); Supabase's own PostgreSQL build may differ from the local tzdata, so the timezone alias map should be re-checked against the live project; the mutation test was not re-run for the new timezone normalisation; the coach evaluation needs a real Anthropic key and has not been re-run with Sonnet; Google Health wire shapes are still UNVERIFIED against a real account; iOS code has not run on a device.
