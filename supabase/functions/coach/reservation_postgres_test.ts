import { assert, assertEquals } from "../_shared/test_helpers.ts";

// Opt-in integration test. The normal suite needs no database, subprocess or env permissions.
const permission = await Deno.permissions.query({
  name: "env",
  variable: "COACH_TEST_DATABASE_URL",
});
const databaseUrl = permission.state === "granted"
  ? Deno.env.get("COACH_TEST_DATABASE_URL")
  : undefined;

Deno.test({
  name:
    "PostgreSQL 16: 20 concurrent reservations enforce user/global caps and service-only access",
  ignore: !databaseUrl,
  fn: async () => {
    const decode = (bytes: Uint8Array) => new TextDecoder().decode(bytes).trim();
    const execute = (sql: string) =>
      new Deno.Command("psql", {
        args: ["-X", "-qAt", "--dbname", databaseUrl!, "--set=ON_ERROR_STOP=1", "--command", sql],
        stdout: "piped",
        stderr: "piped",
      }).output();
    const query = async (sql: string): Promise<string> => {
      const output = await execute(sql);
      assert(output.success, decode(output.stderr));
      return decode(output.stdout);
    };
    const name = await query("select current_database()");
    assert(/^coach_limits_test(?:_|$)/.test(name), "Use an empty coach_limits_test_* scratch DB");
    assert(Number(await query("show server_version_num")) >= 160000, "PostgreSQL 16+ required");
    assertEquals(await query("select to_regclass('public.coach_messages') is null"), "t");

    // Use the existing table DDL verbatim without modifying or applying old migrations/extensions.
    const initial = await Deno.readTextFile(
      new URL("../../migrations/20261106000000_init.sql", import.meta.url),
    );
    const table = initial.match(/create table public\.coach_messages \([\s\S]*?\n\);/);
    assert(table, "Original coach_messages DDL must exist");
    const migration = await Deno.readTextFile(
      new URL("../../migrations/20261119020000_coach_cost_limits.sql", import.meta.url),
    );
    await query(`
      do $$ begin
        if not exists (select from pg_roles where rolname = 'anon') then create role anon; end if;
        if not exists (select from pg_roles where rolname = 'authenticated') then create role authenticated; end if;
        if not exists (select from pg_roles where rolname = 'service_role') then create role service_role; end if;
      end $$;
      create schema auth;
      create table auth.users (id uuid primary key);
      ${table[0]}
      alter table public.coach_messages enable row level security;
      ${migration}
      insert into auth.users select md5(i::text)::uuid from generate_series(1, 20) i;
    `);
    const uid = (i: number) => `md5('${i}')::uuid`;
    const thread = "'00000000-0000-4000-8000-000000000002'::uuid";
    const reserve = (user: string, limit: number, globalLimit: number, question = "question") =>
      `public.reserve_coach_question(${user}, ${thread}, '${question}', ${limit}, ${globalLimit})`;
    const recentCount = () =>
      query(`select count(*) from public.coach_messages
      where role = 'user' and created_at >= now() - interval '24 hours'`);

    for (const role of ["anon", "authenticated"]) {
      const denied = await execute(`set role ${role}; select ${reserve(uid(1), 30, 500)}`);
      assert(!denied.success && decode(denied.stderr).includes("permission denied for function"));
    }
    assertEquals(
      await query(`select count(*) from pg_proc p,
      lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) acl
      where p.oid = 'public.reserve_coach_question(uuid,uuid,text,integer,integer)'::regprocedure
        and acl.grantee = 0 and acl.privilege_type = 'EXECUTE'`),
      "0",
    );

    for (const scope of ["user", "global"]) {
      await query(`truncate public.coach_messages;
        insert into public.coach_messages (user_id, thread_id, role, content, created_at)
          select id, ${thread}, 'user', 'old question', now() - interval '25 hours' from auth.users;
        insert into public.coach_messages (user_id, thread_id, role, content)
          select id, ${thread}, 'assistant', 'kept answer' from auth.users;`);
      const results = await Promise.all(
        Array.from({ length: 20 }, (_, i) =>
          query(`begin; set local role service_role;
          select ${
            reserve(
              uid(scope === "user" ? 1 : i + 1),
              scope === "user" ? 7 : 100,
              scope === "global" ? 7 : 500,
              `parallel-${i}`,
            )
          };
          select pg_sleep(0.05); commit;`)),
      );
      // Each independent connection keeps the reservation lock for 50 ms, forcing contention.
      assertEquals(results.filter((result) => result === "reserved").length, 7);
      assertEquals(
        results.filter((result) => result === (scope === "user" ? "daily_limit" : "coach_busy"))
          .length,
        13,
      );
      assertEquals(await recentCount(), "7");
      assertEquals(await query("select count(*) from public.coach_messages"), "47");
      assertEquals(
        await query(`select max(n) from (
        select count(*) n from public.coach_messages where role = 'user'
          and created_at >= now() - interval '24 hours' group by user_id) counts`),
        scope === "user" ? "7" : "1",
      );
    }

    // The SQL also clamps oversized limits, even if a caller bypasses the handler's clamp.
    await query(`truncate public.coach_messages;
      insert into public.coach_messages (user_id, thread_id, role, content)
        select ${uid(1)}, ${thread}, 'user', 'seed' from generate_series(1, 99);`);
    assertEquals(
      await query(`set role service_role; select ${reserve(uid(1), 999, 1000)}`),
      "reserved",
    );
    assertEquals(
      await query(`set role service_role; select ${reserve(uid(1), 999, 1000)}`),
      "daily_limit",
    );
    assertEquals(await recentCount(), "100");

    await query("truncate public.coach_messages");
    assertEquals(
      await query(`begin; set local role service_role;
      select ${reserve(uid(1), 30, 500)}; rollback;`),
      "reserved",
    );
    assertEquals(await recentCount(), "0");
  },
});
