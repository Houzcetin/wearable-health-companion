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

## Still to do in the Google Cloud console (no CLI for these)

1. **OAuth consent screen** (Google Auth Platform → Branding / Audience / Data access)
   - User type: External. App name, support email, developer contact.
   - Data access: add `openid`, `email`, `profile` and these read-only health scopes:
     - `https://www.googleapis.com/auth/googlehealth.sleep.readonly`
     - `https://www.googleapis.com/auth/googlehealth.activity_and_fitness.readonly`
     - `https://www.googleapis.com/auth/googlehealth.health_metrics_and_measurements.readonly`
     - `https://www.googleapis.com/auth/googlehealth.profile.readonly`
   - Audience: add both team members and every Fitbit Air tester as **test users**.
   - Note: in "Testing" status, refresh tokens expire after 7 days (see PLAN.md).
2. **OAuth clients** (Google Auth Platform → Clients). Redirect URIs:
   - Web client for Supabase sign-in: `https://ftgozpdlwcoiwynqcslh.supabase.co/auth/v1/callback`
   - Web client for connecting Google Health: `https://ftgozpdlwcoiwynqcslh.supabase.co/functions/v1/health-oauth-callback`
   - Android client: package `com.wearablecompanion.wearable_companion` plus the debug keystore SHA-1.
   - iOS client: bundle ID `com.wearablecompanion.wearableCompanion`.
   - Paste the web client ID and secret into `.env` (`GOOGLE_OAUTH_CLIENT_ID`, `GOOGLE_OAUTH_CLIENT_SECRET`).

## Still to do in Supabase
- Auth → Sign In / Providers → Google: turn on, paste the web client ID and secret, add the Android and iOS client IDs as authorized client IDs.

## Still to do elsewhere
- `ANTHROPIC_API_KEY`: create a key in the Anthropic console with a spending limit. It is stored only as a Supabase secret and in `.env`, never in the app.
- `HEALTH_WEBHOOK_SECRET`: generated when the webhook receiver is built (Stage 5).

## Teammate access
Your teammate needs their own `.env`. Share it privately (not through the repo or chat). They also need to be invited to the Google Cloud project (IAM) and the Supabase organization (Team).
