-- QA security hardening. Existing RPCs are replaced in place to preserve their ACLs.

-- Manual workers claim only the authenticated caller's jobs. The int-only overload
-- remains available for cron/service workers claiming the global queue.
create function public.claim_sync_jobs(batch_size int, p_user_id uuid)
returns setof public.sync_queue language sql security definer set search_path = '' as $$
  update public.sync_queue q
     set status = 'running', attempts = q.attempts + 1
   where q.id in (
     select id from public.sync_queue
      where user_id = p_user_id and status = 'pending' and run_after <= now()
      order by run_after
      limit batch_size
      for update skip locked)
  returning q.*;
$$;

-- A single upsert serializes simultaneous calls for the same user, including the
-- first call. Clients cannot read or reset the timestamp to bypass the cooldown.
create table public.user_sync_rate_limits (
  user_id uuid primary key references auth.users on delete cascade,
  last_called_at timestamptz not null
);
alter table public.user_sync_rate_limits enable row level security;
revoke all on public.user_sync_rate_limits from public, anon, authenticated;
grant all on public.user_sync_rate_limits to service_role;

create function public.try_start_user_sync(p_user_id uuid)
returns boolean language plpgsql security definer set search_path = '' as $$
declare called_at timestamptz := clock_timestamp();
begin
  insert into public.user_sync_rate_limits (user_id, last_called_at)
  values (p_user_id, called_at)
  on conflict (user_id) do update
     set last_called_at = excluded.last_called_at
   where user_sync_rate_limits.last_called_at <= excluded.last_called_at - interval '60 seconds';
  return found;
end $$;

revoke execute on function public.claim_sync_jobs(int, uuid), public.try_start_user_sync(uuid)
  from public, anon, authenticated;
grant execute on function public.claim_sync_jobs(int, uuid), public.try_start_user_sync(uuid)
  to service_role;

-- Validate new timezone writes and repair legacy values before using them in dates.
update public.profiles p
   set timezone = 'UTC'
 where char_length(p.timezone) > 64
    or not exists (select 1 from pg_timezone_names where name = p.timezone);

create or replace function public.validate_profile_timezone()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.timezone is null or char_length(new.timezone) > 64
     or not exists (select 1 from pg_timezone_names where name = new.timezone) then
    raise exception 'invalid timezone' using errcode = '22023';
  end if;
  return new;
end $$;

create trigger profiles_validate_timezone before insert or update of timezone on public.profiles
  for each row execute function public.validate_profile_timezone();

-- Resolve timezone names through PostgreSQL's catalog even for legacy/bypassed writes.

create or replace function public.enqueue_recent_sync(p_days int default 2)
returns int language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  insert into public.sync_queue (user_id, data_type, date)
  select c.user_id, t.data_type, d::date
    from public.health_connections c
    left join public.profiles p on p.user_id = c.user_id
    cross join unnest(array['sleep','steps','daily-resting-heart-rate',
                           'daily-heart-rate-variability','active-zone-minutes',
                           'activity-level','total-calories','daily-oxygen-saturation',
                           'exercise']) as t(data_type)
    cross join lateral generate_series(
      (now() at time zone coalesce((select name from pg_timezone_names where name = p.timezone), 'UTC'))::date
        - least(greatest(coalesce(p_days, 2), 0), 7),
      (now() at time zone coalesce((select name from pg_timezone_names where name = p.timezone), 'UTC'))::date,
      interval '1 day') as d
   where c.status = 'active'
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.enqueue_backfill(p_user_id uuid, p_days int default 35)
returns int language plpgsql security definer set search_path = '' as $$
declare
  tz    text;
  today date;
  n     int;
begin
  select coalesce((select name from pg_timezone_names where name = p.timezone), 'UTC') into tz
    from public.profiles p where p.user_id = p_user_id;
  today := (now() at time zone coalesce(tz, 'UTC'))::date;

  insert into public.sync_queue (user_id, data_type, date)
  select p_user_id, t.data_type, d::date
    from unnest(array['sleep','steps','daily-resting-heart-rate',
                      'daily-heart-rate-variability','active-zone-minutes',
                      'activity-level','total-calories','daily-oxygen-saturation',
                      'exercise']) as t(data_type),
         generate_series(today - least(greatest(p_days, 0), 90), today, interval '1 day') as d
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.request_sync(days_back int default 1)
returns int language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  tz  text;
  n   int;
begin
  if uid is null then raise exception 'not authenticated'; end if;
  if not exists (select 1 from public.health_connections
                  where user_id = uid and status = 'active') then
    raise exception 'google health not connected';
  end if;
  select coalesce((select name from pg_timezone_names where name = p.timezone), 'UTC') into tz
    from public.profiles p where p.user_id = uid;
  insert into public.sync_queue (user_id, data_type, date)
  select uid, t.data_type, d::date
    from unnest(array['sleep','steps','daily-resting-heart-rate',
                      'daily-heart-rate-variability','active-zone-minutes',
                      'activity-level','total-calories','daily-oxygen-saturation',
                      'exercise']) as t(data_type),
         generate_series((now() at time zone coalesce(tz,'UTC'))::date - least(greatest(days_back,0),7),
                         (now() at time zone coalesce(tz,'UTC'))::date, interval '1 day') as d
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.seed_demo_metrics(p_user_id uuid, p_days int default 35)
returns int language plpgsql security definer set search_path = '' as $$
declare
  tz    text;
  today date;
  n     int;
begin
  if exists (select 1 from public.daily_metrics
              where user_id = p_user_id and not is_demo) then
    raise exception 'user has real data; refusing to seed demo rows';
  end if;

  select coalesce((select name from pg_timezone_names where name = p.timezone), 'UTC') into tz
    from public.profiles p where p.user_id = p_user_id;
  today := (now() at time zone coalesce(tz, 'UTC'))::date;

  delete from public.daily_metrics where user_id = p_user_id and is_demo;

  insert into public.daily_metrics (
    user_id, date, sleep_minutes, sleep_efficiency, deep_min, rem_min, light_min, awake_min,
    bedtime, wake_time, resting_hr, hrv_ms, spo2_avg,
    steps, active_zone_min, active_min, total_calories, exercise_count,
    source_updated_at, is_demo)
  select
    p_user_id, x.d, x.sleep, 92.0 - x.i % 6,
    round(x.sleep * 0.18)::int, round(x.sleep * 0.22)::int,
    x.sleep - round(x.sleep * 0.18)::int - round(x.sleep * 0.22)::int, 25 + x.i % 15,
    (x.d::timestamp + interval '7 hours' - make_interval(mins => x.sleep + 25 + x.i % 15)) at time zone coalesce(tz, 'UTC'),
    (x.d::timestamp + interval '7 hours') at time zone coalesce(tz, 'UTC'),
    58 + (x.i % 5) + case when x.d = today then 4 else 0 end,
    46 - (x.i % 7) - case when x.d = today then 8 else 0 end,
    96.0 + (x.i % 3) * 0.5,
    7200 + ((x.i * 937) % 4200), 18 + ((x.i * 7) % 35), 30 + ((x.i * 11) % 45),
    2150 + ((x.i * 53) % 500), case when x.i % 3 = 0 then 1 else 0 end,
    now(), true
  from (
    select d::date as d,
           (today - d::date) as i,
           case when d::date = today then 338            -- short night
                else 425 + (((today - d::date) * 37) % 55) - 20
           end as sleep
      from generate_series(today - greatest(p_days - 1, 0), today, interval '1 day') as d
  ) x;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.get_friend_board()
returns table (
  user_id uuid, display_name text, character_name text, avatar_key text,
  level int, xp int, mood text, points_today int, points_week int, best_streak int,
  is_me boolean
) language sql stable security definer set search_path = '' as $$
  with people as (
    select auth.uid() as uid
    union
    select case when f.user_a = auth.uid() then f.user_b else f.user_a end
      from public.friendships f
     where auth.uid() in (f.user_a, f.user_b)
  )
  select p.user_id, p.display_name, c.name, c.avatar_key, c.level, c.xp, c.mood,
         coalesce((select sum(pe.points) from public.point_events pe
                    where pe.user_id = p.user_id
                      and pe.date = (now() at time zone coalesce((select name from pg_timezone_names where name = p.timezone), 'UTC'))::date), 0)::int,
         coalesce((select sum(pe.points) from public.point_events pe
                    where pe.user_id = p.user_id
                      and pe.date >= date_trunc('week', now() at time zone coalesce((select name from pg_timezone_names where name = p.timezone), 'UTC'))::date), 0)::int,
         coalesce((select max(s.current) from public.streaks s where s.user_id = p.user_id), 0),
         p.user_id = auth.uid()
    from people x
    join public.profiles p on p.user_id = x.uid
    join public.characters c on c.user_id = p.user_id
   where auth.uid() is not null
     and (p.user_id = auth.uid() or p.sharing_consent_at is not null)
   order by 9 desc;
$$;

-- Challenge creation and membership both require explicit friend sharing consent.

create or replace function public.join_challenge(cid bigint)
returns void language plpgsql security definer set search_path = '' as $$
declare creator uuid;
begin
  if not exists (select 1 from public.profiles
                  where user_id = auth.uid() and sharing_consent_at is not null) then
    raise exception 'sharing consent required' using errcode = '42501';
  end if;
  select creator_id into creator from public.challenges where id = cid and ends_at >= current_date;
  if creator is null then raise exception 'challenge not found or ended'; end if;
  if creator <> auth.uid() and not public.are_friends(creator, auth.uid()) then
    raise exception 'only friends of the creator can join';
  end if;
  insert into public.challenge_members (challenge_id, user_id) values (cid, auth.uid())
  on conflict do nothing;
end $$;

alter policy own_insert on public.challenges
  with check (creator_id = (select auth.uid()) and exists (
    select 1 from public.profiles
     where user_id = (select auth.uid()) and sharing_consent_at is not null
  ));

-- Check consent before creating or rotating a Vault secret or connection.

create or replace function public.store_health_connection(
  p_user_id        uuid,
  p_health_user_id text,
  p_refresh_token  text,
  p_scopes         text[]
) returns void language plpgsql security definer set search_path = '' as $$
declare
  sid uuid;
begin
  if not exists (select 1 from public.profiles
                  where user_id = p_user_id and health_consent_at is not null) then
    raise exception 'health consent required' using errcode = '42501';
  end if;
  if p_refresh_token is null or p_refresh_token = '' then
    raise exception 'refresh token required';
  end if;

  select refresh_token_secret_id into sid
    from public.health_connections where user_id = p_user_id;

  if sid is null then
    sid := vault.create_secret(
      p_refresh_token,
      'google_health_refresh_' || p_user_id::text,
      'Google Health refresh token');
    insert into public.health_connections
      (user_id, health_user_id, refresh_token_secret_id, scopes, status, last_error, connected_at)
    values (p_user_id, p_health_user_id, sid, p_scopes, 'active', null, now());
  else
    perform vault.update_secret(sid, p_refresh_token);
    update public.health_connections
       set health_user_id = p_health_user_id,
           scopes         = p_scopes,
           status         = 'active',
           last_error     = null,
           connected_at   = now()
     where user_id = p_user_id;
  end if;
end $$;

-- Clients never need these table privileges; RLS does not protect TRUNCATE.
revoke truncate, references, trigger on all tables in schema public from anon, authenticated;
alter default privileges in schema public
  revoke truncate, references, trigger on tables from anon, authenticated;

alter table public.characters
  add constraint characters_avatar_key_length check (char_length(avatar_key) <= 32);

-- Consent timestamps are server-owned even when the client supplies an explicit value.
create or replace function public.set_consent_event_at()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.at := now();
  return new;
end $$;

create trigger consent_events_set_at before insert on public.consent_events
  for each row execute function public.set_consent_event_at();

revoke execute on function public.validate_profile_timezone(), public.set_consent_event_at()
  from public, anon, authenticated;

-- 128 bits of entropy for newly issued invites; existing invite links remain valid.
alter table public.friend_invites
  alter column code set default encode(extensions.gen_random_bytes(16), 'hex');

-- Task metrics are the aggregate fields in daily_metrics (DailyMetrics in the app).
alter table public.tasks
  add constraint tasks_metric_allowed check (metric in (
    'sleep_minutes', 'sleep_efficiency', 'deep_min', 'rem_min', 'light_min', 'awake_min',
    'bedtime', 'wake_time', 'resting_hr', 'hrv_ms', 'spo2_avg', 'steps',
    'active_zone_min', 'active_min', 'total_calories', 'exercise_count'
  ));

-- Challenge metrics are the four values documented by the original challenges schema.
alter table public.challenges
  add constraint challenges_metric_allowed check (metric in (
    'points', 'steps', 'active_zone_min', 'sleep_window'
  ));
