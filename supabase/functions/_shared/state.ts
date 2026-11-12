export interface OAuthState {
  userId: string;
  nonce: string;
  expiresAt: number;
}

const encoder = new TextEncoder();

function encode(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes)).replaceAll("+", "-").replaceAll("/", "_")
    .replace(/=+$/, "");
}

function decode(value: string): Uint8Array<ArrayBuffer> {
  if (!/^[A-Za-z0-9_-]+$/.test(value)) throw new Error("bad_state");
  const padded = value.replaceAll("-", "+").replaceAll("_", "/").padEnd(
    Math.ceil(value.length / 4) * 4,
    "=",
  );
  const bytes = Uint8Array.from(atob(padded), (char) => char.charCodeAt(0));
  if (encode(bytes) !== value) throw new Error("bad_state");
  return bytes;
}

async function key(secret: string): Promise<CryptoKey> {
  if (!secret) throw new Error("OAUTH_STATE_SECRET is required");
  return await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign", "verify"],
  );
}

export async function signState(
  { userId, ttlSeconds }: { userId: string; ttlSeconds: number },
  secret: string,
): Promise<string> {
  if (!userId || !Number.isSafeInteger(ttlSeconds) || ttlSeconds <= 0) {
    throw new Error("Invalid state parameters");
  }
  const payload: OAuthState = {
    userId,
    nonce: encode(crypto.getRandomValues(new Uint8Array(24))),
    expiresAt: Math.floor(Date.now() / 1000) + ttlSeconds,
  };
  const body = encode(encoder.encode(JSON.stringify(payload)));
  const signature = new Uint8Array(
    await crypto.subtle.sign("HMAC", await key(secret), encoder.encode(body)),
  );
  return `${body}.${encode(signature)}`;
}

/** now is Unix time in seconds. WebCrypto verifies the HMAC in constant time. */
export async function verifyState(
  state: string,
  secret: string,
  now = Math.floor(Date.now() / 1000),
): Promise<OAuthState> {
  try {
    if (state.length > 2048) throw new Error("bad_state");
    const parts = state.split(".");
    if (parts.length !== 2) throw new Error("bad_state");
    const [body, mac] = parts;
    const signature = decode(mac);
    if (
      signature.length !== 32 || !await crypto.subtle.verify(
        "HMAC",
        await key(secret),
        signature,
        encoder.encode(body),
      )
    ) throw new Error("bad_state");
    const payload: unknown = JSON.parse(
      new TextDecoder("utf-8", { fatal: true }).decode(decode(body)),
    );
    if (typeof payload !== "object" || payload === null) throw new Error("bad_state");
    const value = payload as Record<string, unknown>;
    if (
      typeof value.userId !== "string" || !value.userId ||
      typeof value.nonce !== "string" || !/^[A-Za-z0-9_-]{32}$/.test(value.nonce) ||
      typeof value.expiresAt !== "number" || !Number.isSafeInteger(value.expiresAt) ||
      !Number.isFinite(now) || value.expiresAt <= now
    ) throw new Error("bad_state");
    return { userId: value.userId, nonce: value.nonce, expiresAt: value.expiresAt };
  } catch {
    throw new Error("bad_state");
  }
}
