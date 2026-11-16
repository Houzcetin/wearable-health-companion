-- Finished workouts use client-generated ids so retries are idempotent.
create table public.workouts (
  id          uuid primary key,
  user_id     uuid not null references auth.users on delete cascade,
  type        text not null check (type in ('walk','run','bike')),
  source      text not null check (source in ('auto','manual')),
  started_at  timestamptz not null,
  ended_at    timestamptz not null,
  steps       int not null check (steps >= 0),
  distance_m  numeric not null check (distance_m >= 0),
  calories    numeric not null check (calories >= 0),
  weight_kg   numeric check (weight_kg between 20 and 400),
  created_at  timestamptz not null default now(),
  check (ended_at > started_at and ended_at <= started_at + interval '24 hours')
);
create index on public.workouts (user_id, started_at desc);

alter table public.workouts enable row level security;
create policy own_select on public.workouts for select to authenticated
  using (user_id = (select auth.uid()));
create policy own_insert on public.workouts for insert to authenticated
  with check (user_id = (select auth.uid()) and exists (
    select 1 from public.profiles
     where user_id = (select auth.uid()) and health_consent_at is not null
  ));
create policy own_delete on public.workouts for delete to authenticated
  using (user_id = (select auth.uid()));

-- Health-only deletion includes workouts, even without a Health connection.
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
  delete from public.workouts where user_id = p_user_id;
  delete from public.health_connections where user_id = p_user_id;
  delete from vault.secrets where id = sid;
end $$;

revoke execute on function public.delete_user_health_data(uuid) from public, anon, authenticated;
grant execute on function public.delete_user_health_data(uuid) to service_role;
