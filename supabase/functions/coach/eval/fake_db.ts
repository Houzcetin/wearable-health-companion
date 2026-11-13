import { createClient } from "npm:@supabase/supabase-js@2";
import { EVAL_TIME_ZONE, type FixtureUser } from "./types.ts";

// This client never delegates to global fetch, including for unexpected routes.
export const fixtureDatabase = (user: FixtureUser) =>
  createClient("https://fixture.invalid", "fixture-key", {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    global: {
      fetch: (input, init) => {
        const request = input instanceof Request ? input : undefined;
        const url = new URL(request?.url ?? String(input));
        const method = (init?.method ?? request?.method ?? "GET").toUpperCase();
        if (method === "GET" && url.pathname === "/rest/v1/profiles") {
          return Promise.resolve(Response.json({
            timezone: EVAL_TIME_ZONE,
            coach_consent_at: "2026-11-01T00:00:00Z",
          }));
        }
        if (method === "POST" && url.pathname === "/rest/v1/rpc/coach_messages_today") {
          return Promise.resolve(Response.json(0));
        }
        if (url.pathname === "/rest/v1/coach_messages") {
          if (method === "POST") {
            return Promise.resolve(new Response(null, { status: 201 }));
          }
          if (method === "GET") return Promise.resolve(Response.json([]));
        }
        if (method === "GET" && url.pathname === "/rest/v1/daily_metrics") {
          let rows = user.rows.slice();
          // PostgREST repeats the date parameter for gte and lte; get() loses one bound.
          for (const filter of url.searchParams.getAll("date")) {
            const [operator, ...parts] = filter.split(".");
            const date = parts.join(".");
            if (operator === "gte") rows = rows.filter((row) => row.date >= date);
            else if (operator === "lte") rows = rows.filter((row) => row.date <= date);
            else if (operator === "eq") rows = rows.filter((row) => row.date === date);
            else throw new Error(`Unsupported fixture date filter: ${operator}`);
          }
          const demo = url.searchParams.get("is_demo");
          if (demo !== null) {
            if (!["eq.true", "eq.false"].includes(demo)) {
              throw new Error("Unsupported fixture demo filter");
            }
            rows = rows.filter((row) => (row.is_demo === true) === (demo === "eq.true"));
          }
          const order = url.searchParams.get("order");
          if (order !== null) {
            if (!["date", "date.asc", "date.desc"].includes(order)) {
              throw new Error("Unsupported fixture order");
            }
            rows.sort((a, b) => a.date.localeCompare(b.date) * (order === "date.desc" ? -1 : 1));
          }
          const limit = url.searchParams.get("limit");
          if (limit !== null) {
            if (!/^\d+$/.test(limit)) throw new Error("Unsupported fixture limit");
            rows = rows.slice(0, Number(limit));
          }
          const select = url.searchParams.get("select");
          const selected = rows.map((row) => {
            if (!select || select === "*") return { ...row };
            return Object.fromEntries(
              select.split(",").map((field) => [
                field,
                row[field as keyof typeof row] ?? null,
              ]),
            );
          });
          return Promise.resolve(Response.json(selected));
        }
        return Promise.resolve(Response.json(
          { message: `Unexpected fixture database route: ${method} ${url.pathname}` },
          { status: 404 },
        ));
      },
    },
  });
