import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";

export const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

export class HttpError extends Error {
  constructor(public status: number, public code: string) {
    super(code);
  }
}

export function requireEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value?.trim()) {
    console.error(`missing_${name}`);
    throw new HttpError(500, "internal_error");
  }
  return value;
}

export function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

export function preflightOrMethod(req: Request, method = "POST"): Response | undefined {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders });
  if (req.method !== method) return jsonResponse({ error: "method_not_allowed" }, 405);
}

export function errorResponse(error: unknown): Response {
  return error instanceof HttpError
    ? jsonResponse({ error: error.code }, error.status)
    : jsonResponse({ error: "internal_error" }, 500);
}

export const timedFetch: typeof fetch = (input, init) => {
  const prior = init?.signal ?? (input instanceof Request ? input.signal : undefined);
  const timeout = AbortSignal.timeout(8000);
  return fetch(input, {
    ...init,
    signal: prior ? AbortSignal.any([prior, timeout]) : timeout,
  });
};

export function createServiceClient(): SupabaseClient {
  return createClient(requireEnv("SUPABASE_URL"), requireEnv("SUPABASE_SERVICE_ROLE_KEY"), {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    global: { fetch: timedFetch },
  });
}

export function bearerToken(req: Request): string {
  const match = /^Bearer ([^\s]+)$/i.exec(req.headers.get("Authorization") ?? "");
  if (!match) throw new HttpError(401, "unauthorized");
  return match[1];
}

export async function requireUserId(req: Request): Promise<string> {
  const jwt = bearerToken(req);
  const client = createClient(requireEnv("SUPABASE_URL"), requireEnv("SUPABASE_ANON_KEY"), {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    global: { fetch: timedFetch },
  });
  const { data, error } = await client.auth.getUser(jwt);
  if (error || !data.user) throw new HttpError(401, "unauthorized");
  return data.user.id;
}

export function sameSecret(left: string, right: string): boolean {
  const a = new TextEncoder().encode(left);
  const b = new TextEncoder().encode(right);
  let difference = a.length ^ b.length;
  for (let i = 0; i < Math.max(a.length, b.length); i++) difference |= (a[i] ?? 0) ^ (b[i] ?? 0);
  return difference === 0;
}
