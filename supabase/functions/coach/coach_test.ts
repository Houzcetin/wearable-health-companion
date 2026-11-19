import { createClient } from "npm:@supabase/supabase-js@2";
import { handler } from "./handler.ts";
import type { CreateMessageParams, ModelMessage } from "./types.ts";
import { assert, assertEquals } from "../_shared/test_helpers.ts";
import { HttpError } from "../_shared/supabase.ts";

const userId = "00000000-0000-4000-8000-000000000001";
const threadId = "00000000-0000-4000-8000-000000000002";
function request(body: unknown = { question: "How was my sleep?", threadId }) {
  return new Request("https://example.test/coach", { method: "POST", body: JSON.stringify(body) });
}
function database(
  options: {
    consent?: boolean;
    count?: number;
    globalCount?: number;
    history?: unknown[];
    failRead?: boolean;
    reservationError?: boolean;
    reservationResult?: unknown;
  } = {},
) {
  const saved: Record<string, unknown>[] = [];
  const queries: URL[] = [];
  const reservations: Record<string, unknown>[] = [];
  const counts = new Map<string, number>([[userId, options.count ?? 0]]);
  let globalCount = options.globalCount ?? options.count ?? 0;
  const db = createClient("https://example.test", "test-key", {
    auth: { persistSession: false, autoRefreshToken: false },
    global: {
      fetch: (input, init) => {
        const url = new URL(String(input));
        queries.push(url);
        if (url.pathname.endsWith("/profiles")) {
          return Promise.resolve(
            Response.json({
              timezone: "Europe/Istanbul",
              coach_consent_at: options.consent === false ? null : "2026-11-01",
            }),
          );
        }
        if (url.pathname.endsWith("/reserve_coach_question")) {
          const args = JSON.parse(String(init?.body));
          reservations.push(args);
          if (options.reservationError) {
            return Promise.resolve(
              Response.json({ message: "private database text" }, { status: 500 }),
            );
          }
          if ("reservationResult" in options) {
            return Promise.resolve(Response.json(options.reservationResult));
          }
          // Model the atomic RPC contract. The PostgreSQL test exercises the real lock and SQL.
          if (globalCount >= args.p_global_limit) {
            return Promise.resolve(Response.json("coach_busy"));
          }
          const count = counts.get(args.p_user_id) ?? 0;
          if (count >= args.p_limit) return Promise.resolve(Response.json("daily_limit"));
          counts.set(args.p_user_id, count + 1);
          globalCount++;
          saved.push({
            user_id: args.p_user_id,
            thread_id: args.p_thread_id,
            role: "user",
            content: args.p_question,
          });
          return Promise.resolve(Response.json("reserved"));
        }
        if (url.pathname.endsWith("/coach_messages")) {
          if (init?.method === "POST") {
            saved.push(JSON.parse(String(init.body)));
            return Promise.resolve(new Response(null, { status: 201 }));
          }
          return Promise.resolve(Response.json(options.history ?? []));
        }
        if (url.searchParams.get("select") === "is_demo") {
          return Promise.resolve(Response.json([{ is_demo: true }]));
        }
        if (options.failRead) {
          return Promise.resolve(
            Response.json({ message: "private provider text" }, { status: 503 }),
          );
        }
        return Promise.resolve(
          Response.json([{ date: "2026-11-12", sleep_minutes: 420, is_demo: true }]),
        );
      },
    },
  });
  return { db, saved, queries, reservations };
}
const done: ModelMessage = {
  stop_reason: "end_turn",
  content: [{ type: "text", text: "This is demo data. On November 12 you slept 7 hours." }],
};
const useTool: ModelMessage = {
  stop_reason: "tool_use",
  content: [
    { type: "thinking", thinking: "opaque thought block", signature: "opaque-signature" },
    {
      type: "tool_use",
      id: "tool-1",
      name: "get_daily_metrics",
      input: { start_date: "2026-11-11", end_date: "2026-11-12" },
    },
  ],
};
const resolver = () => Promise.resolve(userId);
const env = () => undefined;

Deno.test("coach requires a session, consent and available daily allowance before model calls", async () => {
  let calls = 0;
  const createMessage = () => {
    calls++;
    return Promise.resolve(done);
  };
  assertEquals(
    (await handler(request(), {
      ...database(),
      userId: () => Promise.reject(new HttpError(401, "unauthorized")),
      createMessage,
      env,
    })).status,
    401,
  );
  const consent = await handler(request(), {
    ...database({ consent: false }),
    userId: resolver,
    createMessage,
    env,
  });
  assertEquals(consent.status, 403);
  assertEquals(await consent.json(), { error: "coach_consent_required" });
  const limited = await handler(request(), {
    ...database({ count: 30 }),
    userId: resolver,
    createMessage,
    env,
  });
  assertEquals(limited.status, 429);
  assertEquals(await limited.json(), { error: "daily_limit" });
  assertEquals(
    (await handler(request(), {
      ...database({ count: 2 }),
      userId: resolver,
      createMessage,
      env: (name) => name === "COACH_DAILY_LIMIT" ? "2" : undefined,
    })).status,
    429,
  );
  assertEquals(calls, 0);
});

Deno.test("coach runs a tool, preserves every assistant block, saves exact facts and orders history", async () => {
  const store = database({
    history: [
      { role: "assistant", content: "Most recent answer" },
      { role: "user", content: "Earlier question" },
    ],
  });
  const calls: CreateMessageParams[] = [];
  const response = await handler(request(), {
    ...store,
    userId: resolver,
    env,
    now: () => Date.parse("2026-11-12T22:30:00Z"),
    createMessage: (params) => {
      calls.push(params);
      return Promise.resolve(calls.length === 1 ? useTool : done);
    },
  });
  assertEquals(response.status, 200);
  const body = await response.json();
  assertEquals(body.threadId, threadId);
  assertEquals(body.isDemo, true);
  assertEquals(calls.length, 2);
  assertEquals(calls[0].model, "claude-sonnet-5-5");
  assertEquals(calls[0].max_tokens, 1500);
  assertEquals(calls[0].betas, ["server-side-fallback-2026-07-01"]);
  assertEquals(calls[0].fallbacks, "default");
  assertEquals(calls[0].output_config, { effort: "medium" });
  for (const key of ["thinking", "temperature", "top_p", "top_k", "tool_choice"]) {
    assert(!(key in calls[0]));
  }
  assert(String(calls[0].messages[0].content).includes("2026-11-13"));
  assert(String(calls[0].messages[0].content).includes("Europe/Istanbul"));
  assertEquals(calls[0].messages.slice(1).map((message) => message.content), [
    "Earlier question",
    "Most recent answer",
    "How was my sleep?",
  ]);
  assertEquals(calls[1].messages.at(-2)?.content, useTool.content);
  assert(calls[1].messages.at(-2)?.content === useTool.content);
  const results = calls[1].messages.at(-1)!.content;
  assert(Array.isArray(results));
  const result = JSON.parse(String(results[0].content));
  assertEquals(result.missing_dates, ["2026-11-11"]);
  assertEquals(body.facts, {
    tools: [{ name: "get_daily_metrics", input: useTool.content[1].input, result }],
  });
  assertEquals(store.saved.map((row) => row.role), ["user", "assistant"]);
  assertEquals(store.saved[1].facts_json, body.facts);
  assertEquals(store.saved[0].thread_id, threadId);
  assertEquals(store.reservations, [{
    p_user_id: userId,
    p_thread_id: threadId,
    p_question: "How was my sleep?",
    p_limit: 30,
    p_global_limit: 500,
  }]);
  assertEquals(store.queries.filter((url) => url.pathname.endsWith("/coach_messages_today")), []);
  // Reads carry a user filter; inserts carry user_id in the body (checked above).
  for (
    const url of store.queries.filter((url) =>
      !url.pathname.includes("/rpc/") && url.searchParams.has("select")
    )
  ) {
    assertEquals(url.searchParams.get("user_id"), "eq." + userId);
  }
  const history = store.queries.find((url) => url.pathname.endsWith("/coach_messages"))!;
  assertEquals(history.searchParams.get("limit"), "6");
  assertEquals(history.searchParams.get("thread_id"), "eq." + threadId);
  assertEquals(history.searchParams.get("order"), "created_at.desc,id.desc");
});

Deno.test("coach returns error tool results for invalid input and database failures", async () => {
  for (const invalid of [true, false]) {
    const tool = structuredClone(useTool);
    if (invalid) tool.content[1].input = { start_date: "2026-02-30", end_date: "2026-11-12" };
    let calls = 0;
    const response = await handler(request(), {
      ...database({ failRead: !invalid }),
      userId: resolver,
      env,
      createMessage: (params) => {
        calls++;
        if (calls === 1) return Promise.resolve(tool);
        const results = params.messages.at(-1)!.content;
        assert(Array.isArray(results));
        assertEquals(results[0].is_error, true);
        assertEquals(JSON.parse(String(results[0].content)), {
          error: invalid ? "invalid_tool_input" : "tool_unavailable",
        });
        return Promise.resolve(done);
      },
    });
    assertEquals(response.status, 200);
  }
});

Deno.test("coach handles refusal, empty answers, exhaustion, pause_turn and max_tokens", async () => {
  for (const stop_reason of ["refusal", "tool_use", "end_turn"]) {
    const response = await handler(request(), {
      ...database(),
      userId: resolver,
      env,
      createMessage: () => Promise.resolve({ stop_reason, content: [] }),
    });
    assertEquals(response.status, 502);
    assertEquals(await response.json(), { error: "coach_unavailable" });
  }
  let calls = 0;
  const exhausted = await handler(request(), {
    ...database(),
    userId: resolver,
    env,
    createMessage: () => {
      calls++;
      return Promise.resolve({
        stop_reason: "pause_turn",
        content: [{ type: "text", text: "continue" }],
      });
    },
  });
  assertEquals(exhausted.status, 502);
  assertEquals(calls, 3);
  calls = 0;
  assertEquals(
    (await handler(request(), {
      ...database(),
      userId: resolver,
      env,
      createMessage: () => {
        calls++;
        return Promise.resolve(
          calls === 1
            ? { stop_reason: "pause_turn", content: [{ type: "thinking", signature: "keep" }] }
            : { ...done, stop_reason: "max_tokens" },
        );
      },
    })).status,
    200,
  );
});

Deno.test("coach stops repeated tool use after three model calls", async () => {
  const store = database();
  let calls = 0;
  const response = await handler(request(), {
    ...store,
    userId: resolver,
    env,
    createMessage: () => {
      calls++;
      return Promise.resolve(useTool);
    },
  });
  assertEquals(response.status, 502);
  assertEquals(calls, 3);
  assertEquals(store.saved.map((row) => row.role), ["user"]);
});

Deno.test("coach clamps per-user limits, validates configuration and retains model override", async () => {
  for (
    const [setting, expected] of [
      ["200", 100],
      ["1e100", 100],
      ["1", 1],
      ["-1", 30],
      ["0", 30],
      ["1.5", 30],
      ["NaN", 30],
      ["Infinity", 30],
      ["", 30],
    ] as const
  ) {
    const store = database({ count: expected });
    let calls = 0;
    const response = await handler(request(), {
      ...store,
      userId: resolver,
      env: (name) => name === "COACH_DAILY_LIMIT" ? setting : undefined,
      createMessage: () => {
        calls++;
        return Promise.resolve(done);
      },
    });
    assertEquals(response.status, 429);
    assertEquals(store.reservations[0].p_limit, expected);
    assertEquals(calls, 0);
  }
  const response = await handler(request(), {
    ...database(),
    userId: resolver,
    env: (name) => name === "COACH_MODEL" ? "custom-model" : undefined,
    createMessage: (params) => {
      assertEquals(params.model, "custom-model");
      assertEquals(params.max_tokens, 1500);
      return Promise.resolve(done);
    },
  });
  assertEquals(response.status, 200);
});

Deno.test("coach enforces the default global cap and safe global configuration", async () => {
  for (const setting of [undefined, "0", "-1", "1.5", "NaN", "Infinity", ""]) {
    const store = database({ globalCount: 500 });
    const response = await handler(request(), {
      ...store,
      userId: resolver,
      env: (name) => name === "COACH_GLOBAL_DAILY_LIMIT" ? setting : undefined,
      createMessage: () => {
        throw new Error("No model calls allowed at the global cap");
      },
    });
    assertEquals(response.status, 503);
    assertEquals(await response.json(), { error: "coach_busy" });
    assertEquals(store.reservations[0].p_global_limit, 500);
    assertEquals(store.saved, []);
  }
});

for (const scope of ["user", "global"]) {
  Deno.test(`coach handles 20 concurrent requests without exceeding the ${scope} limit`, async () => {
    const store = database();
    let calls = 0;
    const responses = await Promise.all(Array.from({ length: 20 }, () =>
      handler(request(), {
        ...store,
        userId: () => Promise.resolve(scope === "user" ? userId : crypto.randomUUID()),
        env: (name) =>
          name === (scope === "user" ? "COACH_DAILY_LIMIT" : "COACH_GLOBAL_DAILY_LIMIT")
            ? "7"
            : undefined,
        createMessage: () => {
          calls++;
          return Promise.resolve(done);
        },
      })));
    const denied = scope === "user" ? 429 : 503;
    assertEquals(responses.filter((response) => response.status === 200).length, 7);
    assertEquals(responses.filter((response) => response.status === denied).length, 13);
    for (const response of responses) {
      const body = await response.json();
      if (response.status === denied) {
        assertEquals(body, { error: scope === "user" ? "daily_limit" : "coach_busy" });
      }
    }
    assertEquals(calls, 7);
    assertEquals(store.saved.filter((row) => row.role === "user").length, 7);
    assertEquals(store.reservations.length, 20);
  });
}

Deno.test("coach keeps failed attempts reserved and fails closed on reservation errors", async () => {
  const store = database();
  let calls = 0;
  for (let i = 0; i < 2; i++) {
    const response = await handler(request(), {
      ...store,
      userId: resolver,
      env: (name) => name === "COACH_DAILY_LIMIT" ? "1" : undefined,
      createMessage: () => {
        calls++;
        return Promise.reject(new Error("provider failure"));
      },
    });
    assertEquals(response.status, i === 0 ? 502 : 429);
  }
  assertEquals(calls, 1);
  assertEquals(store.saved.map((row) => row.role), ["user"]);
  for (const options of [{ reservationError: true }, { reservationResult: null }]) {
    const response = await handler(request(), {
      ...database(options),
      userId: resolver,
      env,
      createMessage: () => {
        calls++;
        return Promise.resolve(done);
      },
    });
    assertEquals(response.status, 500);
    assertEquals(await response.json(), { error: "database_error" });
  }
  assertEquals(calls, 1);
});

Deno.test("coach rejects bad input and sanitizes model failures", async () => {
  for (
    const body of [{}, { question: " " }, { question: "x".repeat(501) }, {
      question: "ok",
      threadId: "bad",
    }]
  ) {
    assertEquals(
      (await handler(request(body), {
        ...database(),
        userId: resolver,
        env,
        createMessage: () => Promise.resolve(done),
      })).status,
      400,
    );
  }
  for (const error of [new Error("provider details"), new HttpError(429, "coach_busy")]) {
    const response = await handler(request(), {
      ...database(),
      userId: resolver,
      env,
      createMessage: () => Promise.reject(error),
    });
    assertEquals(response.status, error instanceof HttpError ? 429 : 502);
    assertEquals(await response.json(), {
      error: error instanceof HttpError ? "coach_busy" : "coach_unavailable",
    });
  }
});
