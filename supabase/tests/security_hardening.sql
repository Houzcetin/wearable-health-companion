-- Run as the migration owner after all migrations, against a disposable local database.
-- auth.uid() must read request.jwt.claim.sub, as in Supabase's auth schema.
begin;

create function pg_temp.expect_error(command text, expected_state text, expected_message text default null)
returns void language plpgsql as $$
begin
  begin
    execute command;
  exception when others then
    if sqlstate <> expected_state
       or (expected_message is not null and sqlerrm <> expected_message) then
      raise exception 'Unexpected error [%] % for %', sqlstate, sqlerrm, command;
    end if;
    return;
  end;
  raise exception 'Expected error % for %', expected_state, command;
end $$;

insert into auth.users (id, email) values
  ('00000000-0000-4000-8000-000000000001', 'security-a@example.test'),
  ('00000000-0000-4000-8000-000000000002', 'security-b@example.test'),
  ('00000000-0000-4000-8000-000000000003', 'security-c@example.test');

-- Both insert and update normalize aliases before catalog lookup, without raising.
do $$
declare sample record; actual text;
begin
  for sample in select * from (values
    ('Europe/Kiev', 'Europe/Kyiv'),
    ('Asia/Calcutta', 'Asia/Kolkata'),
    ('Asia/Saigon', 'Asia/Ho_Chi_Minh'),
    ('Asia/Katmandu', 'Asia/Kathmandu'),
    ('US/Eastern', 'America/New_York'),
    ('Europe/Istanbul', 'Europe/Istanbul'),
    ('Etc/GMT+5', 'Etc/GMT+5'),
    ('Etc/Unknown', 'UTC'),
    ('Invalid/Zone', 'UTC'),
    ('UTC; drop table x', 'UTC'),
    (repeat('x', 70), 'UTC'),
    ('', 'UTC'),
    (null, 'UTC')
  ) as cases(input, expected) loop
    delete from public.profiles where user_id = '00000000-0000-4000-8000-000000000003';
    insert into public.profiles (user_id, timezone)
    values ('00000000-0000-4000-8000-000000000003', sample.input)
    returning timezone into actual;
    assert actual = sample.expected,
      format('Insert timezone %L became %L, expected %L', sample.input, actual, sample.expected);
    update public.profiles set timezone = 'Europe/Istanbul'
    where user_id = '00000000-0000-4000-8000-000000000003';
    update public.profiles set timezone = sample.input
    where user_id = '00000000-0000-4000-8000-000000000003'
    returning timezone into actual;
    assert actual = sample.expected,
      format('Update timezone %L became %L, expected %L', sample.input, actual, sample.expected);
  end loop;
end $$;

-- Connection creation and token rotation must enforce consent even for the service RPC.
select pg_temp.expect_error($sql$
  select public.store_health_connection('00000000-0000-4000-8000-000000000001',
    'security-health-a', 'synthetic-refresh', '{}')
$sql$, '42501', 'health consent required');
insert into public.consent_events (user_id, kind, granted, at)
values ('00000000-0000-4000-8000-000000000001', 'health_data', true, '2099-01-01');
select public.store_health_connection('00000000-0000-4000-8000-000000000001',
  'security-health-a', 'synthetic-refresh', '{}');
select public.store_health_connection('00000000-0000-4000-8000-000000000001',
  'security-health-a', 'synthetic-rotated', '{}');
do $$ begin
  assert public.get_health_refresh_token('00000000-0000-4000-8000-000000000001') = 'synthetic-rotated';
end $$;
insert into public.consent_events (user_id, kind, granted)
values ('00000000-0000-4000-8000-000000000001', 'health_data', false);
select pg_temp.expect_error($sql$
  select public.store_health_connection('00000000-0000-4000-8000-000000000001',
    'security-health-a', 'must-not-be-stored', '{}')
$sql$, '42501', 'health consent required');
insert into public.consent_events (user_id, kind, granted)
values ('00000000-0000-4000-8000-000000000001', 'health_data', true);

-- Normalized device timezones still allow the scheduled worker to enqueue jobs.
do $$
declare timezone_input text;
begin
  foreach timezone_input in array array[
    'Europe/Kiev', 'Asia/Calcutta', 'Asia/Saigon', 'Etc/Unknown',
    'UTC; drop table x', repeat('x', 70), null
  ] loop
    update public.profiles set timezone = timezone_input
    where user_id = '00000000-0000-4000-8000-000000000001';
    assert public.enqueue_recent_sync(2) = 27, 'normalized timezones must enqueue three dates, nine types';
    assert public.enqueue_recent_sync(2) = 0, 'recent sync must remain idempotent';
    delete from public.sync_queue where user_id = '00000000-0000-4000-8000-000000000001';
  end loop;
end $$;

-- Simulate a bypassed legacy timezone to exercise all five defensive RPC bodies.
alter table public.profiles disable trigger profiles_validate_timezone;
update public.profiles set timezone = 'Invalid/Legacy'
where user_id = '00000000-0000-4000-8000-000000000001';
alter table public.profiles enable trigger profiles_validate_timezone;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000001', true);
do $$ begin
  assert public.enqueue_recent_sync(2) = 27, 'recent sync must enqueue three dates, nine types';
  assert public.enqueue_recent_sync(2) = 0, 'recent sync must be idempotent';
  assert public.enqueue_backfill('00000000-0000-4000-8000-000000000001', 3) = 9;
  assert public.request_sync(4) = 9;
  assert public.seed_demo_metrics('00000000-0000-4000-8000-000000000001', 2) = 2;
  assert (select count(*) from public.get_friend_board()) = 1;
end $$;
update public.profiles set timezone = 'UTC'
where user_id = '00000000-0000-4000-8000-000000000001';

-- Real authenticated writes exercise RLS as well as the SECURITY DEFINER join RPC.
insert into public.challenges (creator_id, title, type, metric, starts_at, ends_at)
values ('00000000-0000-4000-8000-000000000002', 'Security test', 'competitive',
  'steps', current_date, current_date + 1);
select set_config('security_test.challenge_id', currval('public.challenges_id_seq')::text, true);
insert into public.friendships (user_a, user_b)
values ('00000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000002');

set local role authenticated;
update public.profiles set timezone = 'Europe/Kiev' where user_id = auth.uid();
do $$ begin
  assert (select timezone = 'Europe/Kyiv' from public.profiles where user_id = auth.uid());
end $$;
update public.profiles set timezone = 'UTC; drop table x' where user_id = auth.uid();
do $$ begin
  assert (select timezone = 'UTC' from public.profiles where user_id = auth.uid());
end $$;
select pg_temp.expect_error($sql$
  select public.join_challenge(current_setting('security_test.challenge_id')::bigint)
$sql$, '42501', 'sharing consent required');
select pg_temp.expect_error($sql$
  insert into public.challenges (creator_id, title, type, metric, starts_at, ends_at)
  values (auth.uid(), 'No consent', 'competitive', 'steps', current_date, current_date + 1)
$sql$, '42501');
select pg_temp.expect_error('truncate public.daily_metrics', '42501');

insert into public.consent_events (user_id, kind, granted, at)
values (auth.uid(), 'friend_sharing', true, '1900-01-01');
do $$ begin
  assert (select sharing_consent_at = now() from public.profiles where user_id = auth.uid());
  assert (select bool_and(at = now()) from public.consent_events where user_id = auth.uid());
end $$;
select public.join_challenge(current_setting('security_test.challenge_id')::bigint);
-- Repeated joins remain idempotent.
select public.join_challenge(current_setting('security_test.challenge_id')::bigint);
insert into public.challenges (creator_id, title, type, metric, starts_at, ends_at)
values (auth.uid(), 'With consent', 'competitive', 'points', current_date, current_date + 1);
do $$ begin
  assert length(public.create_friend_invite()) = 32, 'invite must contain 16 random bytes as hex';
end $$;
select pg_temp.expect_error($sql$
  select public.set_character('Pip', repeat('x', 33))
$sql$, '23514');
select public.set_character('Pip', repeat('x', 32));
select pg_temp.expect_error($sql$
  insert into public.tasks (user_id, title, metric, comparator, target, period, origin)
  values (auth.uid(), 'Invalid metric', 'user_id', 'gte', 1, 'daily', 'user')
$sql$, '23514');
select pg_temp.expect_error($sql$
  insert into public.challenges (creator_id, title, type, metric, starts_at, ends_at)
  values (auth.uid(), 'Invalid metric', 'competitive', 'user_id', current_date, current_date + 1)
$sql$, '23514');
insert into public.tasks (user_id, title, metric, comparator, target, period, origin)
select auth.uid(), 'Allowed metric', metric, 'gte', 1, 'daily', 'user'
from unnest(array[
  'sleep_minutes','sleep_efficiency','deep_min','rem_min','light_min','awake_min',
  'bedtime','wake_time','resting_hr','hrv_ms','spo2_avg','steps',
  'active_zone_min','active_min','total_calories','exercise_count'
]) as metric;
insert into public.challenges (creator_id, title, type, metric, starts_at, ends_at)
select auth.uid(), 'Allowed metric', 'competitive', metric, current_date, current_date + 1
from unnest(array['points','steps','active_zone_min','sleep_window']) as metric;
-- Consent withdrawal must also prevent an already joined user from calling join again.
insert into public.consent_events (user_id, kind, granted)
values (auth.uid(), 'friend_sharing', false);
select pg_temp.expect_error($sql$
  select public.join_challenge(current_setting('security_test.challenge_id')::bigint)
$sql$, '42501', 'sharing consent required');
reset role;

-- Verify every current table and a future table, for both client roles.
create table public.security_default_privileges_probe (id int);
do $$
declare client_role text; table_name regclass; privilege text;
begin
  foreach client_role in array array['anon', 'authenticated'] loop
    for table_name in select oid::regclass from pg_class
      where relnamespace = 'public'::regnamespace and relkind in ('r', 'p') loop
      foreach privilege in array array['TRUNCATE', 'REFERENCES', 'TRIGGER'] loop
        assert not has_table_privilege(client_role, table_name, privilege),
          format('%s retains %s on %s', client_role, privilege, table_name);
      end loop;
    end loop;
  end loop;
end $$;
set local role anon;
select pg_temp.expect_error('truncate public.daily_metrics', '42501');
reset role;

rollback;
\echo 'security_hardening SQL checks passed'
