-- Google Health connection helpers, backfill, and demo data.
-- Everything here is service-role only: Edge Functions call these, the app never does.

-- ---------------------------------------------------------------------------
-- Demo flag: seeded rows must never be mistaken for real device data.
-- ---------------------------------------------------------------------------
alter table public.daily_metrics
  add column is_demo boolean not null default false;

-- ---------------------------------------------------------------------------
-- Refresh tokens live in Supabase Vault (encrypted at rest). Only the secret id
-- is stored in health_connections.
-- ---------------------------------------------------------------------------
create or replace function public.store_health_connection(
  p_user_id        uuid,
  p_health_user_id text,
  p_refresh_token  text,
  p_scopes         text[]
) returns void language plpgsql security definer set search_path = '' as $$
declare
  sid uuid;
begin
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

create or replace function public.get_health_refresh_token(p_user_id uuid)
returns text language sql stable security definer set search_path = '' as $$
  select s.decrypted_secret
    from public.health_connections c
    join vault.decrypted_secrets s on s.id = c.refresh_token_secret_id
   where c.user_id = p_user_id and c.status = 'active';
$$;

-- ---------------------------------------------------------------------------
-- Backfill: enqueue every data type for the last N local dates (max 90).
-- request_sync() is the user-facing version and is capped at 7 days.
-- ---------------------------------------------------------------------------
create or replace function public.enqueue_backfill(p_user_id uuid, p_days int default 35)
returns int language plpgsql security definer set search_path = '' as $$
declare
  tz    text;
  today date;
  n     int;
begin
  select timezone into tz from public.profiles where user_id = p_user_id;
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

-- ---------------------------------------------------------------------------
-- Demo data: plausible, deterministic rows flagged is_demo, for development
-- without a device. Refuses to touch a user who has real rows. Last night is
-- deliberately a short sleep so the "changed from your usual" insight shows.
-- ---------------------------------------------------------------------------
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

  select timezone into tz from public.profiles where user_id = p_user_id;
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

-- ---------------------------------------------------------------------------
-- Privileges: service role only.
-- ---------------------------------------------------------------------------
revoke execute on function
  public.store_health_connection(uuid, text, text, text[]),
  public.get_health_refresh_token(uuid),
  public.enqueue_backfill(uuid, int),
  public.seed_demo_metrics(uuid, int)
from public, anon, authenticated;

grant execute on function
  public.store_health_connection(uuid, text, text, text[]),
  public.get_health_refresh_token(uuid),
  public.enqueue_backfill(uuid, int),
  public.seed_demo_metrics(uuid, int),
  public.claim_sync_jobs(int)
to service_role;
