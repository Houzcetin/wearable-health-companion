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
  options: { consent?: boolean; count?: number; history?: unknown[]; failRead?: boolean } = {},
) {
  const saved: Record<string, unknown>[] = [];
  const queries: URL[] = [];
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
        if (url.pathname.endsWith("/coach_messages_today")) {
          return Promise.resolve(Response.json(options.count ?? 0));
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
  return { db, saved, queries };
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
      env: () => "2",
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
  assertEquals(calls[0].model, "claude-opus-5-5");
  assertEquals(calls[0].max_tokens, 16000);
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
  assertEquals(calls, 6);
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
