# Setup

Secrets (keys, passwords) live only in `.env`, which is git-ignored. Flutter public settings live in the git-ignored `.env.json`, and local iOS Google IDs live in the git-ignored `app/ios/Flutter/Google.xcconfig`. This file holds IDs and steps only.

## Projects (created 2026-11-11)

| Service | Value |
|---|---|
| Google Cloud project ID | `wearable-health-companion` |
| Google Cloud project number | `83744150851` (use this in webhook URLs) |
| Google Health API | enabled (`health.googleapis.com`) |
| Supabase organization | Wearable Health Companion (free plan) |
| Supabase project ref | `ftgozpdlwcoiwynqcslh` |
| Supabase URL | `https://ftgozpdlwcoiwynqcslh.supabase.co` |
| Supabase region | Frankfurt (`eu-central-1`) |

Dashboards:
- Google Cloud: https://console.cloud.google.com/home/dashboard?project=wearable-health-companion
- Supabase: https://supabase.com/dashboard/project/ftgozpdlwcoiwynqcslh

## Google Auth Platform (done 2026-11-12)

**OAuth consent screen**
- App name "Wearable Health Companion", user type External, publishing status **Testing**.
- Data access (7 scopes):
  - Non-sensitive: `openid`, `userinfo.email`, `userinfo.profile`.
  - Restricted (Google Health):
    - `https://www.googleapis.com/auth/googlehealth.sleep.readonly`
    - `https://www.googleapis.com/auth/googlehealth.activity_and_fitness.readonly`
    - `https://www.googleapis.com/auth/googlehealth.health_metrics_and_measurements.readonly`
    - `https://www.googleapis.com/auth/googlehealth.profile.readonly`
- Test users: 2 of 100 (both team members). **To do:** add every Fitbit Air tester under Audience → Test users.
- In "Testing" status, refresh tokens expire after 7 days (see PLAN.md).

**OAuth clients**

| Name | Type | Client ID | Settings |
|---|---|---|---|
| Web (Supabase sign-in + Google Health) | Web application | `83744150851-vu2gnmvalcrsm27rqlkp0uprenou7pe0.apps.googleusercontent.com` | Redirect URIs: `https://ftgozpdlwcoiwynqcslh.supabase.co/auth/v1/callback` and `https://ftgozpdlwcoiwynqcslh.supabase.co/functions/v1/health-oauth-callback` |
| Android (debug) | Android | `83744150851-pjmue2tse9gcn8pnnum08sbojtnk7ai0.apps.googleusercontent.com` | Package `com.wearablecompanion.wearable_companion`, SHA-1 of the project owner's debug keystore `3C:19:59:B9:06:40:2F:3F:47:C9:EA:56:69:76:7F:D3:A0:C1:44:0A` |
| iOS | iOS | `83744150851-ejo5s0dno0ugu4rqb22k0lvv8q6842l4.apps.googleusercontent.com` | Bundle ID `com.wearablecompanion.wearableCompanion` |

One web client serves both redirect flows. Its secret is in `.env` only and cannot be viewed again in the console; if it is lost, add a new secret on the client's page.

The Android client is tied to one machine's debug keystore. A teammate building on their own machine needs their SHA-1 added: either a second Android client, or a shared debug keystore.

## iOS Google sign-in configuration (done 2026-11-19)

1. In the Google Cloud project's **Google Auth Platform → Clients** (or **APIs & Services → Credentials**), open the **iOS** OAuth client for bundle ID `com.wearablecompanion.wearableCompanion`. Copy its client ID and **iOS URL scheme** (the reversed client ID). For example, `123-example.apps.googleusercontent.com` becomes `com.googleusercontent.apps.123-example`. If using a downloaded `GoogleService-Info.plist`, these are its `CLIENT_ID` and `REVERSED_CLIENT_ID` values; that file does not need to be added to the app.
2. From the repository root, create the local build settings file:

   ```sh
   cp app/ios/Flutter/Google.xcconfig.example app/ios/Flutter/Google.xcconfig
   ```

   Replace both placeholders in `Google.xcconfig`:

   ```xcconfig
   GOOGLE_IOS_CLIENT_ID = YOUR_IOS_CLIENT_ID.apps.googleusercontent.com
   GOOGLE_REVERSED_CLIENT_ID = com.googleusercontent.apps.YOUR_IOS_CLIENT_ID
   ```

   Keep real values in `Google.xcconfig`; only the placeholder `.example` file belongs in version control. Debug, Release and Profile each optionally include it with `#include? "Google.xcconfig"`, so a missing local file does not cause an xcconfig include error. Google sign-in still requires valid values.
3. Set `GOOGLE_IOS_CLIENT_ID` in the root `.env.json` to the **same iOS client ID**, alongside `GOOGLE_WEB_CLIENT_ID` (the web OAuth client ID) and the existing public Supabase settings. Xcode build settings do not automatically become Dart defines. On a Mac, launch from `app/` with:

   ```sh
   flutter run --dart-define-from-file=../.env.json
   ```

Verified against the cached `google_sign_in` **7.2.0** README/initialization source and the locked `google_sign_in_ios` **6.3.8** README/Swift implementation: `CFBundleURLTypes` → `CFBundleURLSchemes` must contain the reversed client ID even when Dart supplies `clientId`. `Runner/Info.plist` reads it from `$(GOOGLE_REVERSED_CLIENT_ID)` and supplies the optional native `GIDClientID` default from `$(GOOGLE_IOS_CLIENT_ID)`. Dart initialization takes precedence over that default; this app still requires the iOS Dart define. The web/server client ID is already passed from Dart, so `GIDServerClientID` is unnecessary.

The configuration item is closed. An Xcode build and Google sign-in on an iPhone, including the nonce check below, still need verification on a Mac/device.

## Supabase Google sign-in (done 2026-11-12)
Configured in `supabase/config.toml` under `[auth.external.google]` and pushed with:
```
supabase config push --project-ref ftgozpdlwcoiwynqcslh
```
- Client IDs: web first, then iOS and Android (authorized for native sign-in).
- The secret is read from `GOOGLE_OAUTH_CLIENT_SECRET` in `.env` when pushing; it is not in the file.
- Other settings in `config.toml` were aligned with the hosted project's defaults so a push changes only what we intend. Always read the push preview before confirming.

## Open items from the first flow (2026-11-12)
- **Nonce check, verified on Android (2026-11-12):** native sign-in with `google_sign_in` 7 works with `skip_nonce_check = false`. Not yet checked on iOS.
- **Emulator needs a Google Play image:** sign-in fails on images without the Play Store. Use an AVD built from `system-images;android-35;google_apis_playstore;x86_64` with a test-user Google account added.
- **Account not linked to Google Health (verified 2026-11-12):** for a Google account that has never set up the Fitbit or Google Health app, `users/me/identity` returns `400 FAILED_PRECONDITION` "The account is not linked to Google Health." The callback reports this as `not_linked` and the app asks the user to set up the app first. A real connection needs a tester whose account has a Google Health profile.
- **Callback logs:** `health-oauth-callback` logs the failure reason and, for Health API errors, Google's status and message (never tokens). Read them with `supabase logs --remote=ftgozpdlwcoiwynqcslh --search "health-oauth" --since 1h`.
- **iOS configuration (done 2026-11-19):** the reversed-client URL scheme and native client ID now use local xcconfig build settings (see above). Xcode build and iPhone sign-in verification remain pending (needs a Mac).
- **Google Health wire shapes:** 11 assumptions marked `UNVERIFIED` in `supabase/functions/_shared/google.ts` and `mapping.ts`. Fixtures are synthetic. Check them against a real account first.
- **First sync takes several runs:** the 35-day backfill is 324 jobs; one `sync-worker` call handles at most 200 jobs or about 40 seconds.
- **Scheduled sync:** solved in Stage 5. pg_cron calls `sync-worker` with an `x-cron-secret` header instead of a key in `Authorization` (see below).

## Demo data without a device
`seed_demo_metrics(p_user_id, p_days)` is a service-role-only RPC that inserts rows flagged `is_demo`. It refuses if the user has real rows. The app shows a "Demo data" chip for such rows. Demo rows appear on Today even before Google Health is connected (only after health-data consent), with a "Sample data, not from your device" note.

## Stage 5 backend (done 2026-11-13)
**Function secrets** (`supabase secrets set`, values only in `.env`; [`.env.example`](../.env.example) lists every name):
- `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`: injected by hosted Supabase, so you do not set them. They are needed in `.env` only for local runs.
- `GOOGLE_OAUTH_CLIENT_ID`, `GOOGLE_OAUTH_CLIENT_SECRET`: the web OAuth client, used by `health-oauth-start`, `health-oauth-callback` and `sync-worker`.
- `OAUTH_STATE_SECRET`: signs the OAuth `state` (random, 32+ bytes).
- `ANTHROPIC_API_KEY`: the coach's Claude key. Set a spending limit in the Anthropic console.
- `HEALTH_WEBHOOK_SECRET`: Google sends `Bearer <secret>` in `Authorization` on every webhook call.
- `SYNC_CRON_SECRET`: pg_cron sends it to `sync-worker` in `x-cron-secret`.
- Optional: `COACH_MODEL` (default `claude-opus-5-5`), `COACH_DAILY_LIMIT` (default 30 questions per 24 h).

**App settings** are not function secrets. They go in the git-ignored `.env.json` (`SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`, `GOOGLE_WEB_CLIENT_ID`, `GOOGLE_IOS_CLIENT_ID`) and are passed with `flutter run --dart-define-from-file=../.env.json`. The Android client needs no ID in the app; it is matched by package name and SHA-1.

**CLI only:** `SUPABASE_DB_PASSWORD` (read by the Supabase CLI) and `GOOGLE_CLOUD_PROJECT_NUMBER` (for manual gcloud/curl calls). Our code reads neither.

**Vault entries** (read by `run_scheduled_sync()`): `project_url` (`https://ftgozpdlwcoiwynqcslh.supabase.co`) and `sync_cron_secret` (same value as `SYNC_CRON_SECRET`). If either is missing, the cron job only enqueues and logs `scheduled_sync_missing_configuration`.

**Cron job** `scheduled-sync`, every 15 minutes: queues the last 2 days for every active connection, then calls `sync-worker`. Check runs with:
```sql
select status, start_time from cron.job_run_details d join cron.job j using (jobid)
 where j.jobname = 'scheduled-sync' order by start_time desc limit 5;
```
First run 2026-11-12 23:15 UTC: succeeded, `sync-worker` returned 200.

**Webhook subscriber** `projects/83744150851/subscribers/whc-main`, created 2026-11-12 with gcloud user credentials (`x-goog-user-project: wearable-health-companion`). Endpoint `.../functions/v1/health-webhook`, nine data types, policy `AUTOMATIC`. State **ACTIVE**, so both verification calls passed. If `HEALTH_WEBHOOK_SECRET` changes, PATCH the subscriber's `endpointAuthorization` too.

**Live checks (2026-11-13):** no session → 401 on `coach`, `export-data`, `delete-account`; webhook 401 without secret, 200 for verification with it, 401 for a bad signature. Export and both delete scopes were tested on throwaway email users (created and deleted again), never on a team account.

**To verify with a real device:** real notification bodies and signatures; scheduled sync fetching real data; Google token revoke on a real connection.

## Teammate access
Your teammate needs their own `.env`. Share it privately (not through the repo or chat). They also need to be invited to the Google Cloud project (IAM) and the Supabase organization (Team).
