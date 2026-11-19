# Cost report (skeleton)

This file lists every cost item, the formula behind it and where to read the real figure. **No prices are filled in here.** Prices change and plans differ, so copy numbers from the invoices and dashboards named below and mark each as measured, estimated or still to fill. Put the date next to every figure.

Dashboard menu names below were written from memory of the current UI and **must be checked**: Supabase, Anthropic and Google Cloud change their consoles, so a path may have moved.

Columns: **Measured** = read from an invoice, dashboard or log. **Estimated** = computed from a formula with stated inputs. **To fill** = not yet known.

## Summary

| Item | Measured | Estimated | To fill | Owner |
|---|---|---|---|---|
| Supabase (plan, Edge Functions, database, egress) | ☐ | ☐ | ☐ | |
| Anthropic API (coach) | ☐ | ☐ | ☐ | |
| Google Cloud and Google Health API | ☐ | ☐ | ☐ | |
| Apple and Google developer accounts | ☐ | ☐ | ☐ | |
| Other (domain, monitoring, test devices) | ☐ | ☐ | ☐ | |
| **Total for the demo period** | | | | |
| **Projected monthly cost at N users** | | | | |

Reporting period: ____ to ____ . Users counted: ____ (testers) / ____ (planned).

## 1. Supabase

Project `ftgozpdlwcoiwynqcslh` in `eu-central-1` (Frankfurt). The organization is on the free plan as of 2026-11-11 (SETUP.md); confirm the current plan before filling this in.

| Line | Formula / driver | Where to read it | Measured | Estimated | To fill |
|---|---|---|---|---|---|
| Plan fee | Plan price × months | Dashboard → Organization → Billing → Subscription | | | |
| Edge Function invocations | Per day ≈ 96 scheduled `sync-worker` calls (every 15 minutes) + webhook notifications + manual **Sync now** + coach, export, delete and OAuth calls | Dashboard → Edge Functions → select a function → Invocations; or Organization → Usage | | | |
| Edge Function compute | Invocations × duration; the worker is bounded to about 38 s per call | Dashboard → Edge Functions → Logs / Metrics | | | |
| Database size | Rows × row size. `daily_metrics` grows one row per user per day; `sync_queue` is transient; `coach_messages` grows with questions; `workouts` with workouts | Dashboard → Reports → Database, or Organization → Usage | | | |
| Database egress and API requests | App reads of `daily_metrics`, `coach_messages`, `workouts` | Dashboard → Reports → API, Organization → Usage | | | |
| Auth monthly active users | Distinct signed-in users per month | Dashboard → Authentication → Usage, Organization → Usage | | | |
| pg_cron / pg_net | Included in the database; the job runs every 15 minutes | Dashboard → Database → Cron (run history); newer dashboards may list it under Integrations → Cron | | | |
| Overage charges | Usage above plan quotas | Organization → Billing → Upcoming invoice | | | |

**Spend cap.** On plans that have it, the Spend Cap is a toggle under **Organization → Billing**. With it on, usage above the included quotas is blocked instead of billed; with it off, overage is charged. Record which setting is active: ____ . Also set a billing alert or budget if the dashboard offers one.

## 2. Anthropic API (coach)

The coach calls the Anthropic API from the `coach` Edge Function with `ANTHROPIC_API_KEY`. The model comes from `COACH_MODEL`. The code default is `claude-opus-5-5` and a Sonnet default is planned, so **record which model was used for each period**: ____ .

**Per-question cost.** A question makes up to six model calls (tool loop). For each call:

```
call cost = input_tokens × input_price + output_tokens × output_price
          (+ cache read / write tokens × their prices, if used)
question cost = sum of its calls   (at most 6 calls)
```

The input includes the stable system prompt, the last six messages and the tool results, so later calls in the same question cost more than the first. Prices are per million tokens; read them from the Anthropic pricing page for the model in use and note the date.

**Where to read it:**

| Figure | Where |
|---|---|
| Tokens and cost per model and day | Anthropic Console → Usage and Cost (filter by API key or workspace) |
| Tokens per eval run | Console usage during an eval run; `docs/eval/*.json` hold the raw answers of the evaluation runs |
| Average questions per active user per day | `select count(*)::float / nullif(count(distinct user_id), 0) from coach_messages where role = 'user' and created_at > now() - interval '1 day'` in the SQL editor (questions in the last 24 hours divided by users who asked) |

**Limits that bound the cost:**

| Limit | Where it is set | Current value |
|---|---|---|
| Questions per user per rolling 24 hours | Function secret `COACH_DAILY_LIMIT` (`supabase secrets set`); the code default is 30 | ____ |
| Question length | In the function, 500 characters | 500 |
| Model calls per question | In the function, at most 6 | 6 |
| Global monthly spend limit | Anthropic Console → Settings → Limits (spend limit and notification threshold; also available per workspace) | ____ |

**Worst-case ceiling for N users:** `N × COACH_DAILY_LIMIT × question cost × 30 days`. There is no global daily ceiling in code yet (see the technical report, known risks), so the Console spend limit is the real cap. Record both numbers: ceiling ____ , limit ____ .

| Line | Measured | Estimated | To fill |
|---|---|---|---|
| Development and evaluation runs (26 questions × 3 repeats per run) | | | |
| Tester sessions (Stage 7) | | | |
| Demo Day | | | |

## 3. Google Cloud and Google Health API

Project `wearable-health-companion` (number in SETUP.md).

| Line | Where to read it | Measured | Estimated | To fill |
|---|---|---|---|---|
| Google Health API usage and quota | Google Cloud console → APIs & Services → Enabled APIs → Google Health API → Metrics and Quotas | | | |
| Charges, if any, for the project | Google Cloud console → Billing → Reports (filter by project) | | | |
| OAuth verification (CASA assessment) | Out of scope; PLAN.md notes it as a paid, multi-week process. Record "not purchased" or the actual invoice | | | |
| Fitbit Air devices for testers | Receipts, if the team buys devices | | | |

**Budget alert.** Create a budget with email alerts under **Billing → Budgets & alerts** even if the expected cost is zero, so a surprise is visible.

## 4. Developer accounts and distribution

| Line | Notes | Where to read it | Measured | To fill |
|---|---|---|---|---|
| Apple Developer Program | Needed for a device build with background modes and for TestFlight | Apple Developer account → Membership; the receipt email | | |
| Google Play Console | Needed only for store or internal-test distribution | Play Console → Payments profile; the receipt email | | |
| Test devices | iPhones and Android phones for the checklists | Receipts | | |

## 5. Per-user cost model

Fill the unit costs from sections 1 to 3, then:

```
monthly cost per active user
  = coach questions per day × 30 × question cost
  + (Supabase usage share per user)
  + (Edge Function share per user)
```

Fixed monthly costs (plan fees) are split across the number of users. Show three scenarios: 5 testers, 50 users, 100 users (the unverified-app cap).

| Scenario | Questions/user/day | Coach | Supabase | Other | Total / month | Per user |
|---|---|---|---|---|---|---|
| 5 testers | | | | | | |
| 50 users | | | | | | |
| 100 users | | | | | | |

## 6. Checklist before Demo Day

- ☐ Anthropic spend limit set and screenshot saved
- ☐ `COACH_DAILY_LIMIT` set to the value above
- ☐ Supabase spend cap setting recorded
- ☐ Google Cloud budget alert created
- ☐ Real figures copied from dashboards with dates
- ☐ "To fill" cells all resolved or marked not applicable
