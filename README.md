# Wearable Health Companion

**See what changed from your usual in 10 seconds.**

A companion app for the Fitbit Air. It reads sleep, heart rate and activity through the official Google Health API, shows a one-screen daily summary with weekly and monthly trends, and has an AI coach that explains changes using the user's own numbers.

Semester project 15, Gen-AI / Mechatronics Lab, Fall 2026.

## Status
Stage 1 (kickoff). The Flutter app is the default template. No backend exists yet.

## Layout
```
app/        Flutter app (Android and iOS)
docs/       Plan and course-stage roadmap
```
`supabase/` (database migrations and Edge Functions) is added in Stage 3.

## Run the app
Requires Flutter (stable channel).
```
cd app
flutter run
```

## Configuration
Copy `.env.example` to `.env` and fill in the values. Never commit `.env`.

## Docs
- [Plan and roadmap](docs/PLAN.md)

## Rules we follow
- This repo is our own work. No code is copied from other teams.
- Store daily aggregates only, never raw streams. Encrypt tokens.
- Wellness wording only: no diagnosis, no medical claims.
- Explicit consent, a privacy notice and a delete option (KVKK).
