-- Retain chat history; bound accepted questions across all users over a rolling 24 hours.
create index coach_questions_created_at_idx on public.coach_messages (created_at)
  where role = 'user';

create function public.reserve_coach_question(
  p_user_id uuid,
  p_thread_id uuid,
  p_question text,
  p_limit int,
  p_global_limit int
)
returns text language plpgsql security definer set search_path = '' as $$
declare
  reserved_at timestamptz;
begin
  if p_user_id is null or p_thread_id is null or p_question is null
     or length(btrim(p_question)) = 0 or length(p_question) > 500
     or p_limit is null or p_limit < 1
     or p_global_limit is null or p_global_limit < 1 then
    raise exception 'invalid_coach_reservation' using errcode = '22023';
  end if;

  -- Always lock the user first, then the shared allowance. The global lock also serializes
  -- reservations for different users. Both count+insert checks use fresh READ COMMITTED
  -- snapshots after waiting; neither transaction lock spans an API call.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_user_id::text, 0));
  perform pg_catalog.pg_advisory_xact_lock(1802462051, 1);
  reserved_at := clock_timestamp();

  if (select count(*) from public.coach_messages
       where role = 'user' and created_at >= reserved_at - interval '24 hours')
       >= p_global_limit then
    return 'coach_busy';
  end if;
  if (select count(*) from public.coach_messages
       where user_id = p_user_id and role = 'user'
         and created_at >= reserved_at - interval '24 hours') >= least(p_limit, 100) then
    return 'daily_limit';
  end if;

  insert into public.coach_messages (user_id, thread_id, role, content, created_at)
  values (p_user_id, p_thread_id, 'user', p_question, reserved_at);
  return 'reserved';
end $$;

revoke execute on function public.reserve_coach_question(uuid, uuid, text, int, int)
  from public, anon, authenticated;
grant execute on function public.reserve_coach_question(uuid, uuid, text, int, int)
  to service_role;
