# Google Health API: working notes

Sources: https://developers.google.com/health (webhooks, migration/api-specifications, app-verification, release-notes). Checked 2026-11-06.

## Basics
- Base URL: `https://health.googleapis.com/v4`
- The legacy Fitbit Web API and Fitbit OAuth endpoints were turned off on 2026-11-02, so they can't be used.
- OAuth scopes use the format `https://www.googleapis.com/auth/googlehealth.<scope>`

| Scope we request | Covers |
|---|---|
| `sleep.readonly` | sleep |
| `activity_and_fitness.readonly` | steps, AZM, activity-level, calories, exercise |
| `health_metrics_and_measurements.readonly` | resting HR, HRV, SpO2 |
| `profile.readonly` | identity / profile |

## Data types → `daily_metrics` columns
| Google `dataType` | Read via | Our column(s) |
|---|---|---|
| `sleep` | list (session) | sleep_minutes, sleep_efficiency, deep/rem/light/awake_min, bedtime, wake_time |
| `steps` | dailyRollUp | steps |
| `active-zone-minutes` | dailyRollUp | active_zone_min |
| `activity-level` | **list** (no rollup) | active_min (moderately + very active) |
| `total-calories` | dailyRollUp | total_calories |
| `daily-resting-heart-rate` | **list** (no rollup) | resting_hr |
| `daily-heart-rate-variability` | **list** (no rollup) | hrv_ms |
| `daily-oxygen-saturation` | **list** (no rollup) | spo2_avg |
| `exercise` | list (session) | exercise_count (used for the run bonus) |

Methods per type follow developers.google.com/health/data-types (checked 2026-11-11). Resting HR, HRV, SpO2 and activity level support only `list` and `reconcile`, not rollups.

To read one day's summary for rollup types: `POST /v4/users/me/dataTypes/<type>/dataPoints:dailyRollUp` with `windowSizeDays: 1`.
Rollup range limits: at most 14 days for `heart-rate` and `total-calories`, 90 days for `steps` and `active-zone-minutes`. The 90-day backfill for calories therefore needs several requests.
Data reaches the API only after the device syncs through the Google Health app.
⚠️ Confirm the exact request and response shapes in week 1 against a real account, and save fixtures to `supabase/functions/_shared/fixtures/`.

Some types depend on the device. The Fitbit Air may not report SpO2 or HRV, so the UI hides cards that have no data.

## Webhooks
- Create the subscriber with the GCP project **number**, endpoint URI, per-type
  `AUTOMATIC` subscriber configs and `endpointAuthorization.secret = "Bearer " +
  HEALTH_WEBHOOK_SECRET`. PATCH replaces the entire subscriber config list.
- Verification is POST `{"type":"verification"}` with User-Agent
  `Google-Health-API-Webhooks`: configured Authorization returns 200; missing
  credentials return 401. An unset server secret fails closed with 500.
- A notification is one object or an array of at most 99 objects. Each object's
  top-level `data` contains `version`, `clientProvidedSubscriptionName`,
  `healthUserId`, `operation` (UPSERT/DELETE), `dataType`, `intervals`, and optional
  `recordId`. The receiver expands the date parts of
  `civilIso8601TimeInterval.startTime/endTime` inclusively, at most 14 distinct dates
  per user/type. Sleep includes the wake-up date. Notifications contain no health values.
- Notifications require the exact Authorization secret plus
  `GOOGLE-HEALTH-API-SIGNATURE`. Base64 decoding yields a 5-byte Tink prefix
  (version byte plus big-endian key ID) and a DER ECDSA P-256/SHA-256 signature over
  the **raw body bytes**. The receiver converts DER to raw r||s for WebCrypto.
- The [public Tink keyset](https://www.gstatic.com/googlehealthapi/webhooks/webhooks_public_keyset.json)
  is cached for one hour; an unknown key ID triggers one refetch. The minimal
  EcdsaPublicKey protobuf parser reads x/y from fields 3/4, skipping params.
  **UNVERIFIED:** confirm this field layout and signature envelope on a live notification.
- The handler groups by health user/type and calls `enqueue_webhook_job`. Unknown
  types and inactive connections are ignored. The pending queue index collapses retries.
  Enqueue completes **before** empty 204; the receiver never invokes the worker.
  Signed malformed JSON returns 204 with a warning code. Invalid signatures return
  401; enqueue failures return 500 for retry.
- Source contract: [Google Health webhooks](https://developers.google.com/health/webhooks).

## Coach tools (Stage 5)
- `coach` accepts an authenticated POST with a 1–500 character `question` and optional
  UUID `threadId`. It requires AI consent and allows 30 questions in a rolling
  24 hours (`COACH_DAILY_LIMIT` overrides). Accepted questions count even if a model call fails.
- `get_daily_metrics {start_date, end_date}` returns allowed daily fields,
  `missing_dates` and `is_demo`. Inclusive ranges are at most 92 days.
- `compare_periods {metric, a_start, a_end, b_start, b_end}` supports sleep duration,
  resting HR, HRV, steps, active zone minutes, deep/REM/awake minutes. Each period has
  `nights_with_data`, missing dates, mean and median. Results include `difference`
  (a minus b), up to three `top_contributors` ranked by absolute deviation from b's
  mean, `enough_data` (at least four observations in each period), and `is_demo`.
  Null/missing values are excluded; computed statistics are rounded to one decimal.
- Both tools filter by the authenticated user. The response is
  `{threadId, answer, facts, isDemo}`; assistant `facts_json` stores exact tool
  inputs/results shown to the model. Prior history is the last six text messages.
- The official Anthropic SDK uses `COACH_MODEL` (default `claude-opus-5-5`), medium
  effort and the specified server fallback beta. The manual loop makes at most six
  calls, preserving every assistant block. Live answer quality remains unverified.

## Verification and limits
- Most Google Health scopes are **restricted**. An unverified app is limited to 100 users, which is enough for the demo.
- Full verification needs a CASA security assessment ($500–4,500, 2–6 weeks). Out of scope for now.
- ⚠️ When the OAuth consent screen is in "Testing" status, refresh tokens expire after about 7 days. Check this in week 1. Before onboarding the 5 testers, either switch the app to "In production" (unverified, testers see a warning screen) or plan weekly re-consent.
- The app must show an in-app disclosure of health data use before consent. A privacy policy alone isn't enough.

## Stage 5 findings (2026-11-13)
- Webhook subscriber creation worked with a gcloud user token plus `x-goog-user-project`; the response is an already-done operation whose `response.state` is `ACTIVE` once both verification POSTs pass.
- The public keyset at gstatic parsed as expected: `ENABLED`, `TINK` prefix, `type.googleapis.com/google.crypto.tink.EcdsaPublicKey`, with x and y in protobuf fields 3 and 4. A real signed notification has not been seen yet.
- Coach: Claude API with two server-side tools, `get_daily_metrics(start_date, end_date)` and `compare_periods(metric, a_start, a_end, b_start, b_end)`. Tool results are stored in `coach_messages.facts_json` and shown in the app under "Numbers used". The app shows plain text, so the prompt forbids Markdown.
