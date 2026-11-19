# Wearable Health Companion

**See what changed from your usual in 10 seconds.**

[![CI](https://github.com/Houzcetin/wearable-health-companion/actions/workflows/ci.yml/badge.svg)](https://github.com/Houzcetin/wearable-health-companion/actions/workflows/ci.yml)

A companion app for the Fitbit Air. It reads sleep, heart rate and activity through the official Google Health API, shows a one-screen daily summary with weekly and monthly trends, and has an AI coach that explains changes using the user's own numbers.

Semester project 15, Gen-AI / Mechatronics Lab, Fall 2026.

## Status
The code for course stages 1 to 6 is in place: Google sign-in with a separate health-data consent, Google Health connection, sync (manual, scheduled and webhook), a one-screen Today summary with usual ranges, week and month Trends, the AI coach with its evaluation, and export and delete. An extra is automatic workout detection (walks, runs and bike rides) with start and stop prompts, notifications and iPhone history suggestions. The Stage 9 documents are written: the [user guide](docs/USER_GUIDE.md), [technical report](docs/TECHNICAL_REPORT.md), [architecture](docs/ARCHITECTURE.md) and a [cost report](docs/COST_REPORT.md) skeleton.

Still open:
- Testing on a real iPhone ([checklist](docs/IPHONE_TEST_CHECKLIST.md)) and with a real Fitbit Air account.
- The Stage 7 five-user beta ([protocol](docs/USER_TEST_PROTOCOL.md)).
- Security fixes from the QA review are in progress (see the technical report, "Known risks and planned fixes").
- Real figures in the cost report.

The Play tab (game layer) is a placeholder and is not part of the required MVP.

## Layout
```
app/        Flutter app (Android and iOS)
supabase/   Postgres migrations and Edge Functions
docs/       Plan, architecture, report, guides, screenshots
```

## Run the app
Requires Flutter (stable channel).
```
cd app
flutter run --dart-define-from-file=../.env.json
```
Without `.env.json` the app still runs as an offline shell.

## Continuous integration
`.github/workflows/ci.yml` runs on every pull request and push to `main`: `flutter analyze` and `flutter test` (Flutter 3.50.0), the workout tests on Chrome, and the Deno tests and type checks for the Edge Functions. It uses no secrets. To run the same checks locally, see `app/lib/features/workouts/README.md` and `supabase/functions/README.md`.

## Configuration
Copy `.env.example` to `.env` and fill in the values. Create `.env.json` for the app as described in `.env.example`. Never commit either file.

## Docs
- [Plan and roadmap](docs/PLAN.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Google Health API notes](docs/API_NOTES.md)
- [Setup: project IDs and console steps](docs/SETUP.md)
- [Technical report](docs/TECHNICAL_REPORT.md) and [cost report](docs/COST_REPORT.md)
- [Coach evaluation](docs/COACH_EVAL.md)
- [User guide](docs/USER_GUIDE.md), [iPhone test checklist](docs/IPHONE_TEST_CHECKLIST.md), [user test protocol](docs/USER_TEST_PROTOCOL.md)
- [Screenshots](docs/screenshots/README.md)

## Rules we follow
- Team members: Oğuz Çetin and Aleksandr Gordeev. The first app shell, schema and architecture come from Aleksandr's `algordeev/health-app`. Nothing is copied from other teams.
- Store daily aggregates only, never raw streams. Encrypt tokens.
- Wellness wording only: no diagnosis, no medical claims.
- Explicit consent, a privacy notice and a delete option (KVKK).
