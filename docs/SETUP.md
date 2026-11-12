# Setup

Secrets (keys, passwords) live only in `.env`, which is git-ignored. This file holds IDs and steps only.

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

## Supabase Google sign-in (done 2026-11-12)
Configured in `supabase/config.toml` under `[auth.external.google]` and pushed with:
```
supabase config push --project-ref ftgozpdlwcoiwynqcslh
```
- Client IDs: web first, then iOS and Android (authorized for native sign-in).
- The secret is read from `GOOGLE_OAUTH_CLIENT_SECRET` in `.env` when pushing; it is not in the file.
- Other settings in `config.toml` were aligned with the hosted project's defaults so a push changes only what we intend. Always read the push preview before confirming.

## Open items from the first flow (2026-11-12)
- **Nonce check, unverified:** the app signs in natively with `google_sign_in` 7 and passes the ID token to Supabase without a nonce, as Supabase's Flutter guide shows. The project has `skip_nonce_check = false`. If sign-in fails on a device with a nonce error, set `skip_nonce_check = true` under `[auth.external.google]` and push the config.
- **iOS:** `ios/Runner/Info.plist` still needs the reversed iOS client ID as a URL scheme for Google sign-in. iOS has not been built (needs a Mac).
- **Google Health wire shapes:** 11 assumptions marked `UNVERIFIED` in `supabase/functions/_shared/google.ts` and `mapping.ts`. Fixtures are synthetic. Check them against a real account first.
- **First sync takes several runs:** the 35-day backfill is 324 jobs; one `sync-worker` call handles at most 200 jobs or about 40 seconds.
- **Scheduled sync:** calling `sync-worker` with an `sb_secret_` key in the `Authorization` header is rejected by the gateway ("Conflicting API keys"). Solve this when adding the cron job.

## Demo data without a device
`seed_demo_metrics(p_user_id, p_days)` is a service-role-only RPC that inserts rows flagged `is_demo`. It refuses if the user has real rows. The app shows a "Demo data" chip for such rows.

## Still to do elsewhere
- `ANTHROPIC_API_KEY`: create a key in the Anthropic console with a spending limit. It is stored only as a Supabase secret and in `.env`, never in the app.
- `HEALTH_WEBHOOK_SECRET`: generated when the webhook receiver is built (Stage 5).

## Teammate access
Your teammate needs their own `.env`. Share it privately (not through the repo or chat). They also need to be invited to the Google Cloud project (IAM) and the Supabase organization (Team).
