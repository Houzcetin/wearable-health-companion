-- Run after all migrations on a disposable PostgreSQL 16 database.
\set ON_ERROR_STOP on
begin;

do $$ begin
  assert current_setting('server_version_num')::int / 10000 = 16,
    'These checks require PostgreSQL 16';
end $$;

insert into auth.users (id, email) values
  ('00000000-0000-4000-8000-000000000011', 'sync-a@example.test'),
  ('00000000-0000-4000-8000-000000000012', 'sync-b@example.test');

-- A's jobs come after B's oldest job. Filtering must precede the batch limit.
insert into public.sync_queue (user_id, data_type, date, status, run_after) values
  ('00000000-0000-4000-8000-000000000012', 'steps', current_date, 'pending', now() - interval '4 minutes'),
  ('00000000-0000-4000-8000-000000000011', 'steps', current_date, 'pending', now() - interval '3 minutes'),
  ('00000000-0000-4000-8000-000000000011', 'sleep', current_date, 'pending', now() - interval '2 minutes'),
  ('00000000-0000-4000-8000-000000000011', 'exercise', current_date, 'pending', now() + interval '1 hour'),
  ('00000000-0000-4000-8000-000000000011', 'total-calories', current_date, 'running', now()),
  ('00000000-0000-4000-8000-000000000011', 'active-zone-minutes', current_date, 'done', now()),
  ('00000000-0000-4000-8000-000000000011', 'activity-level', current_date, 'failed', now());

set local role service_role;
do $$
declare jobs public.sync_queue[];
begin
  select array_agg(q) into jobs from public.claim_sync_jobs(1,
    '00000000-0000-4000-8000-000000000011') q;
  assert cardinality(jobs) = 1;
  assert (jobs[1]).user_id = '00000000-0000-4000-8000-000000000011';
  assert (jobs[1]).data_type = 'steps';
  assert (jobs[1]).status = 'running' and (jobs[1]).attempts = 1;
  assert (select status = 'pending' and attempts = 0 from public.sync_queue
    where user_id = '00000000-0000-4000-8000-000000000012');
  select array_agg(q) into jobs from public.claim_sync_jobs(25,
    '00000000-0000-4000-8000-000000000011') q;
  assert cardinality(jobs) = 1 and (jobs[1]).data_type = 'sleep';
  assert (select count(*) = 0 from public.claim_sync_jobs(25,
    '00000000-0000-4000-8000-000000000011'));
  assert (select count(*) = 0 from public.claim_sync_jobs(25, null)),
    'A null user filter must never claim the global queue';
  select array_agg(q) into jobs from public.claim_sync_jobs(25) q;
  assert cardinality(jobs) = 1;
  assert (jobs[1]).user_id = '00000000-0000-4000-8000-000000000012';
  assert (jobs[1]).attempts = 1 and (jobs[1]).status = 'running';
  assert (select count(*) = 0 from public.claim_sync_jobs()),
    'The original default batch argument must keep working';
end $$;

-- Real table writes check both the cooldown boundary and timestamp preservation.
do $$
declare first_call timestamptz;
begin
  assert public.try_start_user_sync('00000000-0000-4000-8000-000000000011');
  select last_called_at into first_call from public.user_sync_rate_limits
    where user_id = '00000000-0000-4000-8000-000000000011';
  assert not public.try_start_user_sync('00000000-0000-4000-8000-000000000011');
  assert (select last_called_at = first_call from public.user_sync_rate_limits
    where user_id = '00000000-0000-4000-8000-000000000011'),
    'Rejected calls must not extend the cooldown';
  assert public.try_start_user_sync('00000000-0000-4000-8000-000000000012'),
    'Each user must have an independent cooldown';
  update public.user_sync_rate_limits set last_called_at = clock_timestamp() - interval '59 seconds'
    where user_id = '00000000-0000-4000-8000-000000000011';
  assert not public.try_start_user_sync('00000000-0000-4000-8000-000000000011');
  update public.user_sync_rate_limits set last_called_at = clock_timestamp() - interval '60 seconds'
    where user_id = '00000000-0000-4000-8000-000000000011';
  assert public.try_start_user_sync('00000000-0000-4000-8000-000000000011');
  assert not public.try_start_user_sync('00000000-0000-4000-8000-000000000011');
end $$;
reset role;

-- Clients cannot call either claim overload, acquire/reset a rate limit, or read it.
do $$
declare client_role text; signature text; privilege text;
begin
  foreach signature in array array[
    'public.claim_sync_jobs(integer)',
    'public.claim_sync_jobs(integer,uuid)',
    'public.try_start_user_sync(uuid)'
  ] loop
    assert has_function_privilege('service_role', signature, 'EXECUTE');
    foreach client_role in array array['anon', 'authenticated'] loop
      assert not has_function_privilege(client_role, signature, 'EXECUTE'),
        format('%s can execute %s', client_role, signature);
    end loop;
  end loop;
  foreach client_role in array array['anon', 'authenticated'] loop
    foreach privilege in array array['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER'] loop
      assert not has_table_privilege(client_role, 'public.user_sync_rate_limits', privilege);
    end loop;
  end loop;
  assert (select relrowsecurity from pg_class where oid = 'public.user_sync_rate_limits'::regclass);
end $$;
delete from auth.users where id = '00000000-0000-4000-8000-000000000012';
do $$ begin
  assert not exists (select from public.user_sync_rate_limits
    where user_id = '00000000-0000-4000-8000-000000000012');
end $$;

rollback;
\echo 'sync_worker SQL checks passed'
