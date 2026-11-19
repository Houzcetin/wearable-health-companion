#!/usr/bin/env python3
"""Exercise real PostgreSQL 16 lock contention using psql and standard Python only.

Use PGHOST/PGPORT/PGUSER/PGDATABASE for a disposable, migrated database. The
connection must be the migration owner so it can create fixtures and SET ROLE.
"""

import select
import subprocess
import time
import uuid


PSQL = ["psql", "-X", "-qAt", "-v", "ON_ERROR_STOP=1"]


def sql(command):
    return subprocess.run(
        PSQL + ["-c", command], check=True, capture_output=True, text=True, timeout=15
    ).stdout.strip()


def start_session():
    return subprocess.Popen(
        PSQL, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, bufsize=1,
    )


def send(session, command):
    session.stdin.write(command + "\n")
    session.stdin.flush()


def read(session):
    if not select.select([session.stdout], [], [], 10)[0]:
        raise AssertionError("Timed out waiting for psql output")
    result = session.stdout.readline().strip()
    if not result:
        raise AssertionError("Missing psql output: " + session.stderr.read())
    return result


def stop(session):
    if session.poll() is None:
        session.terminate()
    try:
        session.wait(timeout=5)
    except subprocess.TimeoutExpired:
        session.kill()
        session.wait(timeout=5)
    for stream in (session.stdin, session.stdout, session.stderr):
        stream.close()


def rate_race(user_id, expired):
    if expired:
        sql(f"""update public.user_sync_rate_limits
                set last_called_at = clock_timestamp() - interval '61 seconds'
                where user_id = '{user_id}'""")
    first, second = start_session(), start_session()
    name = "sync_rate_test_" + uuid.uuid4().hex
    try:
        send(first, f"""begin; set local role service_role;
             select public.try_start_user_sync('{user_id}');""")
        assert read(first) == "t", "The first caller must acquire the cooldown"
        send(first, f"select last_called_at from public.user_sync_rate_limits where user_id = '{user_id}';")
        timestamp = read(first)
        send(second, f"""set application_name = '{name}'; set role service_role;
             select public.try_start_user_sync('{user_id}');""")
        # Prove that caller two is actually waiting on caller one's uncommitted
        # row, rather than accidentally running sequential requests.
        deadline = time.monotonic() + 10
        while sql(f"""select exists(select from pg_stat_activity
                      where application_name = '{name}' and wait_event_type = 'Lock')""") != "t":
            if second.poll() is not None or time.monotonic() >= deadline:
                raise AssertionError("The concurrent rate check did not wait for the row lock")
            time.sleep(0.05)
        send(first, "commit;")
        assert read(second) == "f", "Only one concurrent caller may acquire the cooldown"
        assert sql(f"select last_called_at from public.user_sync_rate_limits where user_id = '{user_id}'") == timestamp
        assert sql(f"set role service_role; select public.try_start_user_sync('{user_id}')") == "f"
    finally:
        stop(first)
        stop(second)


def claim_race(user_id, other_id):
    sql(f"""insert into public.sync_queue (user_id, data_type, date) values
            ('{user_id}', 'steps', current_date),
            ('{user_id}', 'sleep', current_date),
            ('{other_id}', 'steps', current_date)""")
    first = start_session()
    try:
        send(first, f"""begin; set local role service_role;
             select id from public.claim_sync_jobs(1, '{user_id}');""")
        locked_id = read(first)
        next_id = sql(f"set role service_role; select id from public.claim_sync_jobs(25, '{user_id}')")
        assert next_id.isdigit() and next_id != locked_id, "SKIP LOCKED must claim the other own job"
        assert sql(f"set role service_role; select count(*) from public.claim_sync_jobs(25, '{user_id}')") == "0"
        assert sql(f"select status from public.sync_queue where user_id = '{other_id}'") == "pending"
        assert sql("set role service_role; select user_id from public.claim_sync_jobs(25)") == other_id
        send(first, "commit; select 'committed';")
        assert read(first) == "committed"
    finally:
        stop(first)


def main():
    assert int(sql("show server_version_num")) // 10000 == 16, "PostgreSQL 16 required"
    user_id, other_id = str(uuid.uuid4()), str(uuid.uuid4())
    try:
        sql(f"""insert into auth.users (id, email) values
                ('{user_id}', 'sync-race-{user_id}@example.test'),
                ('{other_id}', 'sync-race-{other_id}@example.test')""")
        rate_race(user_id, expired=False)
        print("ok | concurrent first-ever rate checks: exactly one allowed")
        rate_race(user_id, expired=True)
        print("ok | concurrent expired-cooldown rate checks: exactly one allowed")
        claim_race(user_id, other_id)
        print("ok | scoped claims skip locked own jobs; global claims still work")
    finally:
        sql(f"delete from auth.users where id in ('{user_id}', '{other_id}')")


if __name__ == "__main__":
    main()
