# Edge functions

`health-oauth-start` accepts an authenticated POST and returns the Google consent URL.
`health-oauth-callback` accepts Google's GET redirect, verifies the signed ten-minute state, stores
the connection through the Vault RPC, queues a backfill with `p_days = 35`, and redirects to the
app. The RPC includes today and the previous 35 local dates (36 dates); that inclusivity comes from
the existing SQL.

`sync-worker` accepts a user JWT verified by `auth.getUser`, or the exact service role key. Its
gateway JWT check is disabled so either credential can reach the explicit handler validation. It
drains the shared queue through the existing service-role claim RPC; a user-triggered run can
process other users' queued jobs but returns only counts. It claims at most 25 jobs at once,
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
pending/running jobs. Remaining means all pending/running jobs, including delayed retries. Processed
means jobs handled in this invocation; failed counts handled jobs that did not complete
successfully, including scheduled retries. Backlog rows failed in bulk after revocation are not
counted unless they were handled in this run.

Required runtime settings: `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`,
`GOOGLE_OAUTH_CLIENT_ID`, `GOOGLE_OAUTH_CLIENT_SECRET`, `OAUTH_STATE_SECRET`. They are read through
`Deno.env.get`; no environment files are loaded. OAuth callback errors use only the brief's fixed
redirect reason codes.

Run from the repository root:

```sh
npx -y deno test --config supabase/functions/deno.json supabase/functions/_shared
npx -y deno check --config supabase/functions/deno.json supabase/functions/health-oauth-start/index.ts supabase/functions/health-oauth-callback/index.ts supabase/functions/sync-worker/index.ts
```

The fixtures README documents every unverified real-account assumption. No remote project, Google
account, database, deployment or device is used by these tests.

If the standard runner aborts with Windows named-pipe error 5, the same cases can be executed
without its IPC transport. This fallback does not replace the standard runner's resource/operation
sanitizers:

```sh
npx -y deno run --config supabase/functions/deno.json supabase/functions/_shared/verify_local.ts
```
