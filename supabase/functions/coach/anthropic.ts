import Anthropic from "npm:@anthropic-ai/sdk@1.8.0";
import { HttpError, requireEnv } from "../_shared/supabase.ts";
import type { CreateMessage, ModelMessage } from "./types.ts";

export const createMessage: CreateMessage = async (params) => {
  const client = new Anthropic({ apiKey: requireEnv("ANTHROPIC_API_KEY") });
  try {
    // The handler preserves all SDK content blocks verbatim, including opaque thinking blocks.
    const response = await client.beta.messages.create(
      params as unknown as Anthropic.Beta.MessageCreateParamsNonStreaming,
    );
    return response as unknown as ModelMessage;
  } catch (error) {
    if (error instanceof Anthropic.RateLimitError) throw new HttpError(429, "coach_busy");
    if (error instanceof Anthropic.APIError) throw new HttpError(502, "coach_unavailable");
    throw new HttpError(502, "coach_unavailable");
  }
};
