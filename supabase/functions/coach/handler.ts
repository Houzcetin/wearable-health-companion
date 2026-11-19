import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { localDate } from "../_shared/dates.ts";
import { record } from "../_shared/google.ts";
import { COACH_PROMPT } from "../_shared/coach_prompt.ts";
import {
  COACH_TOOLS,
  comparePeriods,
  DAILY_SELECT,
  dailyMetrics,
  type DailyRow,
  type Metric,
  validateTool,
} from "../_shared/coach_tools.ts";
import {
  createServiceClient,
  errorResponse,
  HttpError,
  jsonResponse,
  preflightOrMethod,
  requireUserId,
} from "../_shared/supabase.ts";
import type { ContentBlock, CreateMessage, Message } from "./types.ts";

interface Dependencies {
  createMessage: CreateMessage;
  db?: SupabaseClient;
  userId?: typeof requireUserId;
  now?: () => number;
  env?: (name: string) => string | undefined;
}
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function check(error: unknown): void {
  if (error) throw new HttpError(500, "database_error");
}

function configuredLimit(value: string | undefined, fallback: number, maximum: number): number {
  const limit = Number(value ?? fallback);
  return Number.isInteger(limit) && limit > 0 ? Math.min(limit, maximum) : fallback;
}

export async function handler(req: Request, deps: Dependencies): Promise<Response> {
  const early = preflightOrMethod(req);
  if (early) return early;
  try {
    const userId = await (deps.userId ?? requireUserId)(req);
    let body: Record<string, unknown>;
    try {
      body = record(await req.json());
    } catch {
      throw new HttpError(400, "invalid_input");
    }
    if (
      typeof body.question !== "string" || !body.question.trim() || body.question.length > 500 ||
      (body.threadId !== undefined &&
        (typeof body.threadId !== "string" || !UUID.test(body.threadId)))
    ) throw new HttpError(400, "invalid_input");
    const threadId = typeof body.threadId === "string" ? body.threadId : crypto.randomUUID();
    const db = deps.db ?? createServiceClient();
    const env = deps.env ?? ((name: string) => Deno.env.get(name));
    const profile = await db.from("profiles").select("timezone,coach_consent_at")
      .eq("user_id", userId).maybeSingle();
    check(profile.error);
    if (!profile.data?.coach_consent_at) throw new HttpError(403, "coach_consent_required");
    const history = await db.from("coach_messages").select("role,content")
      .eq("user_id", userId).eq("thread_id", threadId)
      .order("created_at", { ascending: false }).order("id", { ascending: false }).limit(6);
    check(history.error);
    const demo = await db.from("daily_metrics").select("is_demo")
      .eq("user_id", userId).eq("is_demo", true).limit(1);
    check(demo.error);
    let isDemo = (demo.data?.length ?? 0) > 0;
    const timeZone = profile.data.timezone ?? "UTC";
    const today = localDate((deps.now ?? Date.now)(), timeZone);
    let messages: Message[] = [
      { role: "user", content: `Today: ${today}. Time zone: ${timeZone}. Demo data: ${isDemo}.` },
      ...(history.data ?? []).slice().reverse().map((row): Message => ({
        role: row.role === "assistant" ? "assistant" : "user",
        content: String(row.content),
      })),
      { role: "user", content: body.question },
    ];
    // Reserve both allowances and persist the question atomically, before any model calls.
    // Failed model attempts keep their reservation so repeated failures are also bounded.
    const reservation = await db.rpc("reserve_coach_question", {
      p_user_id: userId,
      p_thread_id: threadId,
      p_question: body.question,
      p_limit: configuredLimit(env("COACH_DAILY_LIMIT"), 30, 100),
      p_global_limit: configuredLimit(env("COACH_GLOBAL_DAILY_LIMIT"), 500, 2147483647),
    });
    check(reservation.error);
    if (reservation.data === "daily_limit") throw new HttpError(429, "daily_limit");
    if (reservation.data === "coach_busy") throw new HttpError(503, "coach_busy");
    if (reservation.data !== "reserved") throw new HttpError(500, "database_error");
    const facts: { tools: { name: string; input: unknown; result: unknown }[] } = { tools: [] };
    const read = async (start: string, end: string): Promise<DailyRow[]> => {
      const result = await db.from("daily_metrics").select(DAILY_SELECT)
        .eq("user_id", userId).gte("date", start).lte("date", end).order("date");
      check(result.error);
      return (result.data ?? []) as unknown as DailyRow[];
    };
    const tool = async (name: string, input: unknown): Promise<unknown> => {
      const args = validateTool(name, input);
      if (name === "get_daily_metrics") {
        return dailyMetrics(
          await read(args.start_date, args.end_date),
          args.start_date,
          args.end_date,
        );
      }
      const [a, b] = await Promise.all([
        read(args.a_start, args.a_end),
        read(args.b_start, args.b_end),
      ]);
      return comparePeriods(
        a,
        b,
        args.metric as Metric,
        args.a_start,
        args.a_end,
        args.b_start,
        args.b_end,
      );
    };
    for (let call = 0; call < 3; call++) {
      let response;
      try {
        response = await deps.createMessage({
          model: env("COACH_MODEL") || "claude-sonnet-5-5",
          max_tokens: 1500,
          betas: ["server-side-fallback-2026-07-01"],
          fallbacks: "default",
          output_config: { effort: "medium" },
          system: COACH_PROMPT,
          tools: COACH_TOOLS,
          messages,
        });
      } catch (error) {
        if (error instanceof HttpError && error.status === 429) throw error;
        throw new HttpError(502, "coach_unavailable");
      }
      if (response.stop_reason === "refusal") throw new HttpError(502, "coach_unavailable");
      if (response.stop_reason === "tool_use") {
        messages = [...messages, { role: "assistant", content: response.content }];
        const results: ContentBlock[] = [];
        for (const block of response.content) {
          if (block.type !== "tool_use") continue;
          if (typeof block.id !== "string" || typeof block.name !== "string") {
            throw new HttpError(502, "coach_unavailable");
          }
          let result: unknown;
          let failed = false;
          try {
            result = await tool(block.name, block.input);
            if (record(result).is_demo === true) isDemo = true;
          } catch (error) {
            failed = true;
            result = {
              error: error instanceof Error && error.message === "invalid_tool_input"
                ? "invalid_tool_input"
                : "tool_unavailable",
            };
          }
          facts.tools.push({ name: block.name, input: block.input, result });
          results.push({
            type: "tool_result",
            tool_use_id: block.id,
            content: JSON.stringify(result),
            ...(failed ? { is_error: true } : {}),
          });
        }
        if (!results.length) throw new HttpError(502, "coach_unavailable");
        messages = [...messages, { role: "user", content: results }];
      } else if (response.stop_reason === "pause_turn") {
        messages = [...messages, { role: "assistant", content: response.content }];
      } else if (["end_turn", "max_tokens"].includes(response.stop_reason ?? "")) {
        const answer = response.content.filter((block) => block.type === "text")
          .map((block) => typeof block.text === "string" ? block.text : "").join("\n").trim();
        if (!answer) throw new HttpError(502, "coach_unavailable");
        const saved = await db.from("coach_messages").insert({
          user_id: userId,
          thread_id: threadId,
          role: "assistant",
          content: answer,
          facts_json: facts,
        });
        check(saved.error);
        return jsonResponse({ threadId, answer, facts, isDemo });
      } else throw new HttpError(502, "coach_unavailable");
    }
    throw new HttpError(502, "coach_unavailable");
  } catch (error) {
    return errorResponse(error);
  }
}
