# Project 15: Wearable Health Companion (revised plan)

Source of truth: *Semester Projects 2026* PDF, pages 34–35 (Project 15) and 37–40 (process, stages, deliverables, ground rules).

## Product promise
**"See what changed from your usual in 10 seconds."**

The 10 seconds is a target we test with users, not a claim. We measure it in Stage 2 (baseline on the official app) and Stage 7 (our app).

## The one connected flow
1. **See what changed.** The daily summary opens on one lead insight, e.g. "You slept 52 min less than your usual." Sleep leads at first. Heart rate and activity stay visible on the same screen, each with its own change against the user's usual.
2. **See when it changed.** Tapping the insight opens that metric's chart with the usual range drawn on it, so the off days stand out.
3. **Ask a follow-up.** A button on the chart opens the coach with the question pre-filled ("Why was this week different?"). The answer lists the dates and numbers it used.

"Usual" means the user's own median over the previous 28 days. If fewer than 7 days exist, the app says "still learning your usual" and shows plain values.

User interviews (Stage 2) decide which metric leads the morning summary. Sleep is the starting assumption.

## Scope

### Required MVP (PDF p. 34)
| Must-have | How we meet it |
|---|---|
| Sign in with Google; consent to Google Health data | Google sign-in, then a separate in-app health-data disclosure and consent step before OAuth |
| One-screen daily summary: sleep, heart rate, activity | Lead insight plus three cards, no scrolling needed |
| Weekly and monthly trends with clear charts | fl_chart, week/month toggle, usual range shown |
| AI coach: plain-language insights from the user's own data | Claude reads daily aggregates through server-side tools; every answer shows its numbers |
| Data export and delete; no medical claims | Export JSON/CSV; delete account removes rows and revokes the token; wellness-only wording |

### Optional, only after every required flow works
Mascot, points, streaks, friend challenges, push notifications, Health Connect on-device data.

### Constraints from the build guide (p. 35) and ground rules (p. 40)
- Store daily aggregates, never raw streams. Encrypt tokens.
- Check which data types the API exposes before designing screens.
- Light RAG: retrieve the user's past weeks before coaching.
- KVKK: explicit consent, a privacy notice and a delete option.
- API keys in `.env` only. Spending limits on every service.
- Both members commit regularly. README and architecture diagram in the repo.
- **Our own team's work only.** `algordeev/health-app` belongs to our teammate (Aleksandr Gordeev), so its docs, schema and scaffold are our team's work and may be reused. We copy nothing from other teams (no-code-sharing rule, p. 37).

## How the coach answers "Why did I sleep badly this week?"
1. **Compare periods.** This week against the user's usual (previous 28 days): sleep duration, efficiency, bedtime, wake time.
2. **Rank the nights.** Each night's shortfall against the usual. The nights that account for most of the weekly drop are named.
3. **Show the evidence.** A "Numbers behind this" card lists the dates and values used.
4. **Look for co-occurring patterns.** For example, later bedtimes or higher activity on the same days. These are worded as "on these nights you also…", never as causes.
5. **Handle missing data.** Nights with no data are listed as missing and left out of averages. With fewer than 4 nights in the week, the coach says the week is too incomplete to compare.
6. **Stay factual and wellness-focused.** No diagnosis, no medical claims. Numbers come only from tool results, computed in SQL, not by the model.

## Roadmap by course stage (PDF p. 38)
Owners: **Mobile** = Flutter app, **Backend** = Supabase, Google Health API, Claude. Assign names in Stage 1.

| Stage | Focus | Owner | Working demo | Definition of done |
|---|---|---|---|---|
| 1 | Kickoff | Both | Spec, user flow, repo, stack, backend and auth plan. Empty app running on a phone. | Own repo created, both members have committed. One-page spec with the promise and the connected flow. GCP and Supabase projects exist. All "To verify" items below have an owner. |
| 2 | Know your users | Both | Notes from 5+ interviews with Fitbit or other wearable users. | Each interview records what they check first in the morning and how long it takes in their current app. Decision written down: which metric leads the summary. |
| 3 | Foundations | Backend (Mobile: sign-in UI) | Google sign-in, health consent, and a real Fitbit Air account's data landing in the database. | Refresh token stored encrypted. `daily_metrics` has real rows. List of data types the Fitbit Air actually returns. 3+ days of our values compared with the official app, differences explained. Dashboard design not final until this passes. |
| 4 | First flow | Both | Live: Google sign-in → health-data consent → sync → daily summary, with a manual "Sync now". | A new user completes the whole flow on a real phone with no developer help. The summary shows sleep, heart rate and activity with change against usual. |
| 5 | Core MVP (midterm demo) | Mobile: charts, export/delete UI. Backend: automated sync, coach v1, export/delete. | All five must-haves working. The connected flow works end to end. | Automated sync (webhook receiver plus a scheduled re-pull) runs without the button. Week and month charts. Coach answers from the user's data. Export downloads a file. Delete removes the data and revokes access. |
| 6 | AI quality | Backend (Both write the test set) | Test set and measured results for the coach. | 20+ questions over fixture users, including missing-data weeks. Every answer checked for: numbers match the data, dates shown, no causal or medical wording. Results table in the report. Failures fixed or listed. Results: [COACH_EVAL.md](COACH_EVAL.md) (26 questions × 3, 90% passed every check). |
| 7 | Beta | Both | 5 real users, findings and fixes. | The comparison protocol below run with 5 users. Results table: completion time, correctness, hesitation points per user and app. Top 3 problems fixed. |
| 8 | Cross-testing | Both | Testing Agent and peer teams test the app. | Every reported bug triaged. Critical ones fixed. Fix list in the report. |
| 9 | Polish | Both | Demo rehearsal with cost and security review. | Cost report drafted. No secrets in the repo, RLS checked (user A cannot read user B). Docs written. Full Demo Day run-through timed. Backup account and recorded video ready. |
| 10 | Demo Day | Both | Live product, demo video, and scope a), b), c). | Checklist below fully ticked. |

### Sync order
Manual "Sync now" comes first (Stage 4). Webhooks and scheduled sync come only after the first flow works (Stage 5). "Sync now" stays in the app as the Demo Day fallback.

### Five-user comparison protocol (Stage 7, Demo Day scope b)
- Each user wears a Fitbit Air or uses an account with real data. **To verify:** how 5 users get access to devices.
- Same task in both apps, in alternating order: "What changed in your sleep last night compared with your usual?" Then one heart-rate and one activity question.
- Record per task: completion time, whether the answer was correct, and where they hesitated.
- Also record whether our morning numbers match the official app's for that day.

## Verified from Google's official docs (checked 2026-11-11)
Sources: developers.google.com/health (overview, data-types, webhooks, app-verification, migration/api-specifications) and developers.google.com/identity/protocols/oauth2.

- **API:** the Google Health API (`https://health.googleapis.com/v4`) replaces the Fitbit Web API, which was scheduled to be turned off on 2026-11-02.
- **Fitbit Air:** named in the data-types page for sleep and daily oxygen saturation.
- **Scopes:** `https://www.googleapis.com/auth/googlehealth.{scope}.readonly`. We need `sleep`, `activity_and_fitness`, `health_metrics_and_measurements` and `profile`. Most are restricted.
- **Read methods per data type:**

| Data type | Methods |
|---|---|
| `sleep`, `exercise` | list, get, reconcile |
| `steps`, `active-zone-minutes`, `heart-rate` | list, reconcile, rollup, dailyRollup |
| `total-calories` | rollup, dailyRollup |
| `daily-resting-heart-rate`, `daily-heart-rate-variability`, `daily-oxygen-saturation`, `activity-level` | list, reconcile only |

- **Range limits:** rollups cover at most 14 days for heart rate and total calories, and 90 days for steps and active zone minutes. A 28-day "usual" for the 14-day types needs several requests.
- **Sync path:** data reaches the API only after the device syncs through the Google Health app. The live demo depends on the phone syncing first.
- **Unverified app:** capped at 100 users. Full verification (CASA, $500–4,500, 2–6 weeks) is out of scope.
- **Refresh tokens:** expire after 7 days while the consent screen is in "Testing" status, because we request health scopes. Before the Stage 7 beta we either publish the consent screen or have testers reconnect weekly.
- **In-app disclosure:** mandatory, shown inside the app during normal use, describing the data and how it is used. A privacy policy alone is not enough.
- **Webhooks:**
  - Create the subscriber with the project **number**, not the project ID.
  - The endpoint must pass two verification POSTs: 200 or 201 with our secret, 401 or 403 without it.
  - Notifications carry no health values, only user, data type and dates. We fetch the data afterwards.
  - Reply 204 at once. Failures are retried for up to 7 days, so handlers must tolerate duplicates.
  - Each notification is signed (ECDSA P-256, header `GOOGLE-HEALTH-API-SIGNATURE`); signing keys rotate every 30 days.
  - Notifications are not backfilled, so the first sync after connecting is a manual pull.

**Correction to the cloned repo's notes:** it planned to read resting heart rate, HRV and SpO2 with `dailyRollUp`. The docs list only `list` and `reconcile` for those types.

## To verify (still open)
These need a real device or account, in Stages 1–3.
- **Fitbit Air access:** do we have a device, and can 5 testers use one or a shared account?
- **Student project access:** the docs state no region or account restriction, but the Cloud setup page was not read. Confirm by enabling the API in our own GCP project.
- **Per-device coverage:** the docs name Fitbit Air only for sleep and SpO2. Confirm with real data that resting heart rate, HRV, steps and active zone minutes arrive.
- **Number parity:** whether the API's daily values match the official app's morning screen.
- **Unverified-app warning:** what testers see on the consent screen.
- **Public team repo:** `algordeev/health-app` is public, so a second team on Project 15 could copy from it. Consider making it private.

## Weekly Google Drive report (PDF p. 39)
Updated before every weekly 5-minute demo. Show working screens, not slides.
- Progress: what was done, what's next.
- Systems and tools used, and why.
- Key prompts that worked, and those that didn't.
- Errors encountered and how we solved them.
- Next week's goal, set from the live feedback.

## Final deliverables (PDF p. 39)
**The product**
- [ ] Live product working at a public link. **To verify:** what counts as a public link for a mobile app (APK download, TestFlight or a web build).
- [ ] Demo video, 2–3 minutes, high quality.
- [ ] Code repository with a README and setup steps.
- [ ] `.env.example`; no secrets in the repo.

**The documentation**
- [ ] Detailed technical report.
- [ ] Architecture diagram.
- [ ] Evaluation: test sets and user-test findings.
- [ ] Cost report: API and hosting spend.
- [ ] Short user guide.

## Demo Day checklist
**a) A real Fitbit Air account connected and syncing live**
- [ ] Account connected before the session; token refreshed that morning.
- [ ] New activity recorded on stage, then shown arriving in the app.
- [ ] "Sync now" ready if the automated sync is slow.
- [ ] Backup account and screen recording ready.

**b) 5 users compare our morning summary with the official app**
- [ ] Results table from all 5 users: time, correctness, hesitation points.
- [ ] Side-by-side screenshots of the same morning in both apps.
- [ ] The 10-second target reported honestly, met or not.

**c) "Why did I sleep badly this week?" answered with the numbers behind it**
- [ ] Asked live on an account with a real worse week.
- [ ] Answer names the nights that contributed most.
- [ ] Dates and numbers visible on screen.
- [ ] Missing nights stated; patterns not presented as causes.

## First three tasks
1. **Confirm Fitbit Air access and API access (Both).** Find out whether we have a device, then read the official Google Health API docs for scopes, data types and OAuth limits. Fill in the "To verify" list.
2. **Create our own repo and projects (Backend).** New empty repo, GCP project with the Health API enabled and the consent screen configured, Supabase project. Both members make a first commit.
3. **Book 5 user interviews and write the question sheet (Mobile).** Include the timed task on their current app, so we have the baseline for the 10-second target.
