# Wearable Health Companion

**See what changed from your usual in 10 seconds.**

[![CI](https://github.com/Houzcetin/wearable-health-companion/actions/workflows/ci.yml/badge.svg)](https://github.com/Houzcetin/wearable-health-companion/actions/workflows/ci.yml)

A companion app for the Fitbit Air. It reads sleep, heart rate and activity through the official Google Health API, shows a one-screen daily summary with weekly and monthly trends, and has an AI coach that explains changes using the user's own numbers.

Semester project 15, Gen-AI / Mechatronics Lab, Fall 2026.

## Status
Stage 1 (kickoff). The app shell has tabs for Today, Trends, Coach, Play and Settings with placeholder screens. Google Cloud and Supabase are set up and Google sign-in is enabled. The database schema is written but not yet applied.

## Layout
```
app/        Flutter app (Android and iOS)
supabase/   Postgres migrations and auth config (Edge Functions come next)
docs/       Plan, architecture, API notes, setup
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

## Rules we follow
- Team members: Oğuz Çetin and Aleksandr Gordeev. The first app shell, schema and architecture come from Aleksandr's `algordeev/health-app`. Nothing is copied from other teams.
- Store daily aggregates only, never raw streams. Encrypt tokens.
- Wellness wording only: no diagnosis, no medical claims.
- Explicit consent, a privacy notice and a delete option (KVKK).
