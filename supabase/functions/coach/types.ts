// Minimal SDK boundary: content blocks remain opaque except for text and tool use.
// This keeps the handler and its tests independent of the SDK's runtime import.
export interface ContentBlock {
  type: string;
  [key: string]: unknown;
}
export interface Message {
  role: "user" | "assistant";
  content: string | ContentBlock[];
}
export interface CreateMessageParams {
  model: string;
  max_tokens: number;
  betas: string[];
  fallbacks: "default";
  output_config: { effort: "medium" };
  system: string;
  tools: typeof import("../_shared/coach_tools.ts").COACH_TOOLS;
  messages: Message[];
}
export interface ModelMessage {
  content: ContentBlock[];
  stop_reason: string | null;
}
export type CreateMessage = (params: CreateMessageParams) => Promise<ModelMessage>;
