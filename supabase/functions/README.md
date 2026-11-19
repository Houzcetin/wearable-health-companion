# Edge functions

`health-oauth-start` accepts an authenticated POST and returns the Google consent URL.
`health-oauth-callback` accepts Google's GET redirect, verifies the signed ten-minute state, stores
the connection through the Vault RPC, queues a backfill with `p_days = 35`, and redirects to the
app. The RPC includes today and the previous 35 local dates (36 dates); that inclusivity comes from
the existing SQL.

`sync-worker` accepts a user JWT verified by `auth.getUser`, the configured `x-cron-secret`, or
the exact service role bearer key. Its gateway JWT check is disabled so these credentials reach
the explicit handler validation. Only cron/service calls claim the global queue through
`claim_sync_jobs(batch_size)`. User calls always use `claim_sync_jobs(batch_size, p_user_id)` with
the verified caller's ID for every batch; request bodies cannot override that ID. Both claim
signatures are executable only by the service role. Remaining counts have the same user/global
scope as claims.

The app's "Sync now" first calls `request_sync(days_back: 1)`, then invokes `sync-worker` directly
with its user JWT and parses the worker's processed/failed/remaining counts. Before any user claim,
the service calls `try_start_user_sync(p_user_id)`: an atomic database upsert in
`user_sync_rate_limits` permits at most one invocation per user per 60 seconds, including across
concurrent requests and worker instances. This table and RPC are service-role only. A rejected
call returns HTTP 429 with `{"error":"sync_rate_limited"}` without claiming jobs; the app displays
"Sync already in progress. Try again in a minute." Cron/service calls bypass this rate limit.

Users without health consent are skipped before any connection or Vault token is read.
The worker claims at most 25 jobs at once,
processes at most 200, and stops fetching at about 38 seconds. Unstarted claims are returned without
consuming a retry attempt. Database settlement can add a bounded request timeout after the fetching
budget. Each request has an eight-second timeout. Mapped fields for a user/date are merged into a
single sparse upsert; absent fields are preserved. Empty data marks its job done without writing a
row or changing demo data. `source_updated_at` is the successful fetch/write time because most daily
responses lack source timestamps.

Transient failures retry after 30, 60, 120 or 240 seconds, then fail on attempt 5. Only short
application/provider status codes are stored in `last_error`. Revoked grants mark the connection
revoked and fail that user's pending/running backlog. If a retry collides with a newer pending
duplicate, that duplicate retains the work and the running row is marked done as superseded.
`last_synced_at` advances only for users without a failure in the invocation and without
pending/running jobs. Remaining means pending/running jobs within the caller's scope, including delayed retries. Processed
means jobs handled in this invocation; failed counts handled jobs that did not complete
successfully, including scheduled retries. Backlog rows failed in bulk after revocation are not
counted unless they were handled in this run.

Required runtime settings: `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`,
`GOOGLE_OAUTH_CLIENT_ID`, `GOOGLE_OAUTH_CLIENT_SECRET`, `OAUTH_STATE_SECRET`. They are read through
`Deno.env.get`; no environment files are loaded. OAuth callback errors use only the brief's fixed
redirect reason codes.

Run from the repository root:

```sh
npx -y deno test --config supabase/functions/deno.json supabase/functions
npx -y deno check --config supabase/functions/deno.json supabase/functions/health-oauth-start/index.ts supabase/functions/health-oauth-callback/index.ts supabase/functions/sync-worker/index.ts
```

The fixtures README documents every unverified real-account assumption. No remote project, Google
account, database, deployment or device is used by these Deno tests. PostgreSQL 16 regression and
concurrency checks are documented in [../tests/README.md](../tests/README.md).

The coach suite includes mocked 20-request concurrency tests. To also exercise the real
reservation RPC, create an **empty scratch database** named `coach_limits_test_local` on
PostgreSQL 16+, with a test administrator that can create roles and schemas, and install `psql`.
From the repository root, run (adjust the local URL as needed):

```sh
COACH_TEST_DATABASE_URL=postgresql://localhost/coach_limits_test_local \
  deno test --config supabase/functions/deno.json \
    --allow-env=COACH_TEST_DATABASE_URL --allow-run=psql --allow-read=supabase/migrations \
    supabase/functions/coach/reservation_postgres_test.ts
```

This opt-in test creates minimal auth/chat tables and applies only the new coach cost migration.
It sends 20 simultaneous requests through independent PostgreSQL connections for each cap, checks
that only 7 are accepted, and verifies permissions, the 100-question clamp and retained history.
It leaves fixture tables in the scratch database; drop that database after the run. It is skipped
by the normal Deno test command and requires no Anthropic key or API calls.

If the standard runner aborts with Windows named-pipe error 5, the same cases can be executed
without its IPC transport. This fallback does not replace the standard runner's resource/operation
sanitizers:

```sh
npx -y deno run --config supabase/functions/deno.json supabase/functions/_shared/verify_local.ts
```
