-- Stage 5: automated sync, coach limits, and health-data deletion.

create or replace function public.delete_user_health_data(p_user_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare sid uuid;
begin
  -- Lock the connection while removing its Vault secret and local health data.
  select refresh_token_secret_id into sid
    from public.health_connections where user_id = p_user_id for update;
  delete from public.daily_metrics where user_id = p_user_id;
  delete from public.sync_queue where user_id = p_user_id;
  delete from public.weekly_insights where user_id = p_user_id;
  delete from public.coach_messages where user_id = p_user_id;
  delete from public.summary_feedback where user_id = p_user_id;
  delete from public.health_connections where user_id = p_user_id;
  delete from vault.secrets where id = sid;
end $$;

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
      (now() at time zone coalesce(p.timezone, 'UTC'))::date
        - least(greatest(coalesce(p_days, 2), 0), 7),
      (now() at time zone coalesce(p.timezone, 'UTC'))::date,
      interval '1 day') as d
   where c.status = 'active'
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.enqueue_webhook_job(
  p_health_user_id text, p_data_type text, p_dates date[]
) returns int language plpgsql security definer set search_path = '' as $$
declare
  uid uuid;
  n int;
begin
  if p_data_type is null or p_data_type <> all(array[
    'sleep','steps','daily-resting-heart-rate','daily-heart-rate-variability',
    'active-zone-minutes','activity-level','total-calories','daily-oxygen-saturation','exercise'
  ]) then return 0; end if;
  select user_id into uid from public.health_connections
   where health_user_id = p_health_user_id and status = 'active';
  if uid is null then return 0; end if;

  insert into public.sync_queue (user_id, data_type, date)
  select uid, p_data_type, dates.d
    from (select distinct d from unnest(p_dates) as d
           where d is not null order by d limit 14) as dates
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.coach_messages_today(p_user_id uuid)
returns int language sql stable security definer set search_path = '' as $$
  select count(*)::int from public.coach_messages
   where user_id = p_user_id and role = 'user' and created_at >= now() - interval '24 hours';
$$;

-- The first sync after connecting is still the backfill plus manual pulls.
-- Provision project_url and sync_cron_secret in Vault separately; no secrets belong here.
create or replace function public.run_scheduled_sync()
returns void language plpgsql security definer set search_path = '' as $$
declare
  project_url text;
  secret text;
begin
  perform public.enqueue_recent_sync(2);
  select decrypted_secret into project_url from vault.decrypted_secrets where name = 'project_url';
  select decrypted_secret into secret from vault.decrypted_secrets where name = 'sync_cron_secret';
  if nullif(btrim(project_url), '') is null or nullif(btrim(secret), '') is null then
    raise notice 'scheduled_sync_missing_configuration';
    return;
  end if;
  perform net.http_post(
    url := project_url || '/functions/v1/sync-worker',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', secret),
    body := '{}'::jsonb,
    timeout_milliseconds := 55000);
end $$;

revoke execute on function
  public.delete_user_health_data(uuid),
  public.enqueue_recent_sync(int),
  public.enqueue_webhook_job(text, text, date[]),
  public.coach_messages_today(uuid),
  public.run_scheduled_sync()
from public, anon, authenticated;

grant execute on function
  public.delete_user_health_data(uuid),
  public.enqueue_recent_sync(int),
  public.enqueue_webhook_job(text, text, date[]),
  public.coach_messages_today(uuid),
  public.run_scheduled_sync()
to service_role;

do $$
declare job bigint;
begin
  for job in select jobid from cron.job where jobname = 'scheduled-sync' loop
    perform cron.unschedule(job);
  end loop;
end $$;
select cron.schedule('scheduled-sync', '*/15 * * * *', 'select public.run_scheduled_sync()');
