# Database regression checks

Use a **disposable local PostgreSQL 16 database**, with all repository migrations
applied and Supabase's `auth`, Vault, cron, and net schemas available. Connect as
the migration owner, able to `SET ROLE service_role`. These scripts never use a
remote project or provider credentials.

From the repository root, set `PGHOST`, `PGPORT`, `PGUSER`, and `PGDATABASE` for
that database, then run:

```sh
psql -X -v ON_ERROR_STOP=1 -f supabase/tests/security_hardening.sql
psql -X -v ON_ERROR_STOP=1 -f supabase/tests/sync_worker.sql
python3 supabase/tests/sync_worker_concurrency.py
```

`security_hardening.sql` covers the other hardening changes. `sync_worker.sql`
checks user filtering before the batch limit, multiple scoped batches, job
eligibility and attempts, the original global/default signatures, a null user
filter, service-only RPC/table privileges, independent per-user cooldowns,
rejection without timestamp changes, the 60-second boundary, and account deletion.
Both SQL files roll back their fixtures.

The concurrency script requires only Python's standard library and `psql`. It
opens two real database sessions and verifies lock contention before allowing
the first transaction to commit. Exactly one call succeeds for both a first-ever
user and an expired cooldown. It also checks scoped `SKIP LOCKED` claims while
another scoped transaction holds a job, and global claiming of the other user's
job. It commits temporary fixtures for cross-session visibility and deletes its
randomly identified users in a `finally` block; their dependent rows cascade.

For checks on plain PostgreSQL without the Supabase extensions, local test doubles
may supply the auth/Vault/cron/net interfaces. Claiming, rate limiting, privileges,
RLS, constraints, triggers, and concurrency must still run in real PostgreSQL 16;
such a run does not validate Vault encryption, cron scheduling, or HTTP delivery.
