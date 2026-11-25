# Technical report: Wearable Health Companion

Final-delivery report. Companion documents: [ARCHITECTURE.md](ARCHITECTURE.md) (diagrams and data flows), [PLAN.md](PLAN.md), [SETUP.md](SETUP.md), [API_NOTES.md](API_NOTES.md), [COACH_EVAL.md](COACH_EVAL.md), [COST_REPORT.md](COST_REPORT.md), [USER_GUIDE.md](USER_GUIDE.md), [IPHONE_TEST_CHECKLIST.md](IPHONE_TEST_CHECKLIST.md), [USER_TEST_PROTOCOL.md](USER_TEST_PROTOCOL.md).

Numbers marked "≈" are counted from source or from one local run and can drift. Everything marked **in progress** is a known gap whose fix is under way; this report is updated when those pull requests merge.

## 1. Purpose and promise

Wearable owners open a companion app to answer one question: *what changed from my usual?* The product promise is **"See what changed from your usual in 10 seconds."** The 10 seconds is a target we test with users (the protocol is in USER_TEST_PROTOCOL.md), not a claim.

The app reads sleep, heart rate and activity for a Fitbit Air through the official Google Health API v4 (the legacy Fitbit Web API was switched off on 2026-11-02). It opens on one lead insight ("You slept 52 min less than typical."), shows heart rate and activity with their own comparison, lets the user see the days that stood out, and adds an AI coach that explains a period in plain language and shows the numbers it used. It is for general wellness and makes no medical claims.

## 2. Scope

**Required MVP (course brief):**

| Must-have | Status |
|---|---|
| Google sign-in; consent to Google Health data | Done: native sign-in, then a separate in-app disclosure and consent step before OAuth |
| One-screen daily summary: sleep, heart rate, activity | Done: lead sentence plus three cards with usual-range bars |
| Weekly and monthly trends with clear charts | Done: week/month toggle, usual range drawn, days outside listed |
| AI coach from the user's own data | Done: server-side tools, every answer shows its numbers |
| Data export and delete; no medical claims | Done: JSON export, delete health data, delete account |

**Extra: auto-detect workouts.** The phone's activity recognition and step counter detect walks, runs and bike rides, ask the user to start and stop, and save the workout to Supabase. On iPhone it also finds workouts that happened while the app was closed and offers them as suggestions. This was not in the brief.

**Not built:** the optional game layer (character, points, streaks, friends, challenges). The tables exist but no code uses them ([ARCHITECTURE.md](ARCHITECTURE.md), section 7).

## 3. Architecture summary

A Flutter app (Riverpod, go_router, supabase_flutter) talks to Supabase: Postgres with row-level security, Vault for secrets, pg_cron and pg_net for scheduled sync, and seven Edge Functions (Deno). Google Health supplies data through OAuth and webhooks; Anthropic powers the coach. On iPhone a small Swift layer wraps CoreMotion and a background refresh task. Diagrams of the system, sync, coach, workout detection, backfill and export/delete are in [ARCHITECTURE.md](ARCHITECTURE.md).

Key decisions:

- **Two-step auth.** Identity first (Google sign-in to Supabase), then a separate Google Health connection. The refresh token is stored in Vault and never reaches the client.
- **Daily aggregates only.** No raw intraday streams are stored.
- **The app reads its own rows under RLS** and calls Edge Functions only for work that needs a secret or the service role. Workouts are the one thing the app inserts itself.
- **"Usual" is the user's own history.** *Typical* is the median of the previous 28 days; the *usual range* is the 10th to 90th percentile of the same days, never narrower than a fixed margin (15 minutes of sleep, 2 bpm, 10% of steps). A day inside the range is "in your usual range"; outside it is "below" or "above". Fewer than 7 days of data means "still learning".

## 4. Data model

Postgres in Frankfurt, 18 tables, RLS enabled on every one ([ARCHITECTURE.md](ARCHITECTURE.md), section 4 has the column summary).

- **Identity and consent:** `profiles` (timezone, consent timestamps), `consent_events` (audit trail; a trigger keeps the profile timestamps in step).
- **Health data:** `health_connections` (status, scopes, Vault secret id only), `daily_metrics` (one row per user per local date; sleep, resting HR, HRV, SpO2, steps, active zone minutes, active minutes, calories, exercise count, `is_demo`), `sync_queue`.
- **Coach:** `coach_messages` (thread, role, content, `facts_json` with the exact tool results).
- **Workouts:** `workouts` (client-generated UUID, type walk/run/bike, source auto/manual, start, end, steps, distance, calories, weight; a check keeps a workout within 24 hours).
- **Prepared, unused:** `weekly_insights`, `summary_feedback`, and the nine game-layer tables.

**RLS in short.** Users can read their own rows. Writes to health data, connections, the queue and coach messages are service-role only. Users can insert `consent_events`, their own workouts (only after health consent), feedback and tasks, and can delete their own workouts. Server-side RPCs (`claim_sync_jobs`, `get_health_refresh_token`, `delete_user_health_data` and others) are `SECURITY DEFINER` with a fixed `search_path` and execute rights only for the roles that need them.

## 5. Sync design

Three triggers feed one queue: the user's **Sync now**, a **15-minute pg_cron job** that queues the last three local dates for all nine data types of every active connection, and **Google webhooks** that queue the affected dates. One worker drains the queue.

- **Idempotent.** A unique index on user, data type and date while pending collapses duplicate webhook deliveries. Google retries failed webhooks for up to seven days, so duplicates are expected.
- **Webhooks carry no health values.** `health-webhook` verifies the secret and the ECDSA P-256 signature (Tink keyset cached for an hour), enqueues and replies 204 at once.
- **Bounded worker.** At most 25 jobs claimed at once, 200 per call, about 38 seconds of fetching, eight seconds per request. Transient errors retry after 30 to 240 seconds and fail on the fifth attempt. A revoked grant marks the connection revoked.
- **Sparse merge.** Mapped fields for a user and date are merged into one upsert, so a late sleep record does not erase steps.
- **Backfill.** Connecting queues today plus the previous 35 local dates. Rollup limits (14 days for calories, 90 for steps) force several requests.
- **Civil dates.** Google rolls up by civil date, so everything is keyed by the user's local date and timezone.

Open points: 13 `UNVERIFIED` markers remain in code (grep count on `main`) until checked against a real account (SETUP.md, "Open items").

## 6. Coach design and evaluation

**Design.** The model never computes numbers. Two deterministic tools read the caller's aggregates: `get_daily_metrics` (inclusive range of at most 92 days, with missing dates and demo flag) and `compare_periods` (two periods, mean and median per period, the difference, up to three contributing days, and an `enough_data` flag that needs four observations per period). The system prompt requires dates and numbers, forbids diagnosis, treatment advice and causal claims, and requires saying when data is missing or demo. The coach loop makes at most six model calls, loads the last six messages of the thread, stores the exact tool results with the answer and returns them for the **Numbers used** panel. A separate consent screen precedes first use because daily summaries go to an AI service. Limits: 500 characters per question, 30 questions per user per rolling 24 hours (`COACH_DAILY_LIMIT`). The model is a setting (`COACH_MODEL`); the code default is `claude-opus-5-5` and a move to a Sonnet default is planned.

**Evaluation.** 26 questions over 8 fixture users (steady, bad week, missing week, gaps, new user, active, empty, demo), asked three times each against the real coach handler with a fake database and a fixed clock, graded by code rules only. Result of the final run: **70 of 78 answers (90%) passed every check**; 2 of the 8 failures are real coach errors (one over the word limit, one "because of" wording) and 6 are false alarms of the checks. Numbers always matched the tool data (78/78). Details, the failure table and the prompt changes are in [COACH_EVAL.md](COACH_EVAL.md).

**Limits of the evaluation.** English only, fixture data only, word-rule checks that can miss subtle wording. Results on real Fitbit Air data are untested until Stage 7.

## 7. Workout detection

**State machine** (diagram in ARCHITECTURE.md, 3.3). The detector is pure Dart and tick-driven; time passes only through `tick()`, never through timers inside the domain.

| Setting | Value |
|---|---|
| Minimum recognition confidence | 75 |
| Start prompt after | walk 10 min, run 3 min, bike 5 min of continuous activity |
| Gap tolerated inside an activity | up to 60 s |
| Start prompt timeout, then cooldown | 2 min, then 30 min |
| Stop prompt after no movement | 5 min; prompt times out after 2 min |
| End time on Finish or timeout | the last movement, not after the idle wait |
| Manual Stop | the current time |

Phases: idle → candidate → prompting start → active → prompting stop → finished. A workout includes the activity time before the user accepted, so a walk that began 10 minutes ago starts 10 minutes ago.

**Metrics.** Steps come from the phone's step counter (the logical counter stays monotonic when the device counter resets). Distance is steps × stride (0.75 m by default), calories are MET × weight × duration, and pace comes from distance. **Bike rides have no distance or pace:** the phone does not measure it, and the UI says so.

**Foreground and background.** While the app runs, an `AppLifecycleListener` shows the start and stop sheets when the app is resumed and posts a local notification with actions when it is not (Start / Not now, Stop / Keep going). Notification permission is requested only from the settings button, never implicitly. Prompt identifiers reject stale actions after a timeout or process termination.

**Backfill on iPhone.** `MotionHistorySource` (CoreMotion over a method channel) looks at up to 24 hours of motion on cold start and resume. Only high-confidence records count; one uncertain record of up to two minutes is bridged once inside a walk. Each bout is replayed through a fresh detector with a fake clock and the normal minimums, producing a **review** ("Did you walk 09:10–09:45?") with Save or Discard. Reviews are never saved automatically. A native `BGAppRefreshTask` (`com.wearablecompanion.workouts.refresh`) can post "Looks like you walked 35 min — tap to log it"; it uses its own cursor so a reminder never consumes a review. iOS decides if and when it runs. Dart and Swift share one golden fixture so both replays agree.

**Persistence.** A finished workout gets a stable id and goes through `WorkoutRepository`. Signed in with health consent, it is queued per account in SharedPreferences (at most 200 rows and 30 days, oldest dropped silently) and inserted into `workouts` ignoring duplicates, retrying with backoff. Without an account or consent it lives in memory for the session. The queue is cleared on sign-out, on consent withdrawal and after a successful deletion.

Full details and the iPhone verification list: [`app/lib/features/workouts/README.md`](../app/lib/features/workouts/README.md).

## 8. Security and privacy

**QA security review (summary).** The database layer was tested on a real PostgreSQL with separate users: RLS is enabled on all 18 tables, and users cannot read, change or delete other users' data; every SECURITY DEFINER function has a fixed search_path and EXECUTE granted only to the roles that need it; health data and OAuth tokens are not reachable from the client (Vault, service role only). Edge Functions authenticate themselves (user JWT, cron secret or signed webhook) and do not leak details in error responses; no secrets were found in the git history. Error responses carry only short codes (one exception: missing-configuration codes name the variable).

**Google sign-in on iOS.** Supabase's Google nonce check is turned off (`skip_nonce_check = true`) because the Google iOS SDK sets its own nonce, which the app cannot pass to Supabase, and sign-in failed with the check on. Supabase still verifies the token signature, the audience (our client IDs) and expiry. What is lost is the binding of the token to this app's session, which would stop a replayed token. This is a documented trade-off, not an oversight; see SETUP.md, "Nonce check".

**Privacy design.** Only daily aggregates and finished workouts are stored. The in-app disclosure explains what is read and stored before consent; consent is logged in `consent_events` and the coach has its own consent. Users can export their data and delete health data or the whole account. Secrets live in function secrets, Vault and git-ignored files; `.env.example` lists names only. The coach sees only the caller's rows through tools that filter by the authenticated user, and its prompt forbids medical claims. This is not a medical product.

### Known risks and planned fixes

The QA review found the following. Items marked Done were fixed in the pull request named in their row; the rest are still open.

| Risk | Detail | Status |
|---|---|---|
| Sync worker access | A user-triggered `sync-worker` call used to drain the shared queue. Now each verified user gets a per-user claim with a rate limit (`try_start_user_sync`, `user_sync_rate_limits`); the global `claim_sync_jobs` is granted to the service role only. Merged in PR #19. | Done |
| Timezone validation | `profiles.timezone` is normalised on write and repaired on migration: old zone names map to current ones, and unknown or malformed values become `UTC` instead of failing. Merged in PR #19. The alias map should be re-checked against the live project's tzdata. | Done |
| Coach cost limits | Sonnet by default, `max_tokens` 1500, at most three model calls, an atomic `reserve_coach_question` reservation with per-user and global 24-hour limits (`COACH_GLOBAL_DAILY_LIMIT`). Merged in PR #23. The evaluation has not yet been re-run with the new model. | Done |
| Health consent on the server | `store_health_connection` checks health consent before it creates a Vault secret, and the `workouts` insert policy requires consent. Other server functions were not audited for consent. | Partly done |
| `join_challenge` and sharing consent | `join_challenge` now requires sharing consent for both the challenge and the member. Merged in PR #19. | Done |
| Table privileges | `anon` and `authenticated` no longer hold `TRUNCATE`, `REFERENCES` or `TRIGGER` on public tables, and the default privileges are changed too. Merged in PR #19. | Done |
| Mobile secure storage and backups | The pending workout queue is kept in SharedPreferences and session tokens are stored as plain text. Android `allowBackup` is not set, and iOS device backups can copy both. Planned: Keychain and Keystore storage and backup exclusion. | In progress |
| Default `display_name` | The signup trigger still defaults `display_name` to the e-mail prefix, which can expose an address fragment on a future friends board. | In progress |
| Export scope | Export covers profile, consent events, connection status, daily metrics, coach messages and workouts. `weekly_insights`, `summary_feedback` and derived game data are not included; the export is being extended. | In progress |
| "Delete health data" and derived game data | Deleting health data does not delete derived game-layer rows (for example points or streaks). Left unchanged on purpose by the team's decision; the export is extended so the user can see that data. | Accepted |

## 9. Test strategy

| Layer | What runs | Size |
|---|---|---|
| Flutter widget and unit tests (VM) | Today, Trends, Coach, Settings, auth flow, usual-range math, workout detector, repository, pending queue, notifications bridge, history review | 355 tests passing in one local run, plus 12 screenshot tests that run on demand |
| Workout tests on Chrome | The workout widget and detector suites also run with `flutter test --platform chrome`; this found a web integer-shift bug (32-bit shifts) now guarded by a source-scan test | 57 tests in that command |
| Deno tests (Edge Functions) | Webhook signature, queue, mapping, worker, coach tools and handler, export, delete, routes | 104 tests passing (88 test blocks, some parameterised) |
| Golden fixture | `workout_motion_history.json` read by the Dart golden test and by RunnerTests' `testMotionHistoryGolden`, so Dart and Swift produce the same bouts | 27 cases |
| iOS RunnerTests | Replay helper, active-marker expiry, revision handling | 4 test functions, run on a Mac with ⌘U |
| Coach evaluation | 26 questions × 3 repeats, rule-based checks with their own unit tests | 78 answers per run |
| Screenshot generator | `SCREENSHOTS=1 flutter test --tags screenshots test/screenshots` renders the main screens in light and dark | 18 images in `docs/screenshots/` |
| QA review | Mutation-style checks of the tests and the real-PostgreSQL RLS test | Reported by QA; the scripts are not in the repository |
| Static analysis | `flutter analyze --no-fatal-infos`: no errors or warnings (SDK deprecation infos remain) | – |

## 10. Known limitations

- **iPhone: build and sign-in only.** The app builds and signs in on an iPhone 17 Pro (iOS 26.5), verified on 2026-11-19. The Swift code, CoreMotion history, background refresh and notifications have been tested only through unit tests and golden fixtures, not on a device. The remaining checks are in [IPHONE_TEST_CHECKLIST.md](IPHONE_TEST_CHECKLIST.md).
- **Android has no background workout detection.** It gets live detection and notifications while the app runs. True background detection needs a native activity-recognition delivery path and a foreground service.
- **No bike distance or pace.** Bike rides record duration and an estimated calorie figure only.
- **Real-data accuracy untested.** Fixtures are synthetic; whether Fitbit Air reports every metric, and whether our values match the official app, is a Stage 3 and Stage 7 question.
- **Google consent screen in Testing.** Refresh tokens expire after about seven days and the app is capped at 100 users until verified (out of scope).
- **Coach limits.** English only, evaluated on fixtures, occasionally slightly over the word limit.
- **Queue limits.** The pending workout queue holds 200 rows and 30 days; older rows are dropped silently.

## 11. Next steps

1. Merge the in-progress security fixes (section 8) and update this report.
2. Run the remaining iPhone checks (background notifications, BGTask, motion history, RunnerTests) on a real device; fix what they find.
3. Run the five-user comparison (USER_TEST_PROTOCOL.md) and fix the top three problems.
4. Fill in the cost report with real invoices and set the spend limits it lists.
5. Decide the coach's default model and re-run the evaluation with it.
6. Optional if time remains: the game layer, an Android native detection path, and weekly insights.
