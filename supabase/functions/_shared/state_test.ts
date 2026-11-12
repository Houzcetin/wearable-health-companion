import { signState, verifyState } from "./state.ts";
import { assert, assertEquals, assertRejects } from "./test_helpers.ts";

const secret = "a-test-secret-that-is-not-a-live-credential";

Deno.test("state round trip includes a unique nonce and ten-minute expiry", async () => {
  const before = Math.floor(Date.now() / 1000);
  const token = await signState({ userId: "user-1", ttlSeconds: 600 }, secret);
  const decoded = await verifyState(token, secret);
  assertEquals(decoded.userId, "user-1");
  assert(decoded.expiresAt >= before + 600 && decoded.expiresAt <= before + 601);
  assert(/^[A-Za-z0-9_-]{32}$/.test(decoded.nonce));
  const another = await verifyState(
    await signState({ userId: "user-1", ttlSeconds: 600 }, secret),
    secret,
  );
  assert(decoded.nonce !== another.nonce);
});

Deno.test("state rejects expiry at the exact boundary and afterwards", async () => {
  const token = await signState({ userId: "user-1", ttlSeconds: 600 }, secret);
  const state = await verifyState(token, secret);
  await verifyState(token, secret, state.expiresAt - 1);
  await assertRejects(() => verifyState(token, secret, state.expiresAt), "bad_state");
  await assertRejects(() => verifyState(token, secret, state.expiresAt + 1), "bad_state");
});

Deno.test("state rejects changed payload, changed signature and wrong secret", async () => {
  const token = await signState({ userId: "user-1", ttlSeconds: 600 }, secret);
  const [payload, mac] = token.split(".");
  await assertRejects(() => verifyState(`${payload.slice(0, -2)}AA.${mac}`, secret), "bad_state");
  await assertRejects(
    () => verifyState(`${payload}.${mac[0] === "A" ? "B" : "A"}${mac.slice(1)}`, secret),
    "bad_state",
  );
  await assertRejects(() => verifyState(token, "wrong-secret"), "bad_state");
});

Deno.test("state rejects malformed envelopes and signed malformed payloads", async () => {
  for (const value of ["", ".", "a.b.c", "%%.%%", "a.a", "x".repeat(3000)]) {
    await assertRejects(() => verifyState(value, secret), "bad_state");
  }
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  for (const payload of [null, {}, { userId: "user-1", nonce: "short", expiresAt: 9999999999 }]) {
    const body = btoa(JSON.stringify(payload)).replaceAll("+", "-").replaceAll("/", "_").replace(
      /=+$/,
      "",
    );
    const bytes = new Uint8Array(
      await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body)),
    );
    const mac = btoa(String.fromCharCode(...bytes)).replaceAll("+", "-").replaceAll("/", "_")
      .replace(/=+$/, "");
    await assertRejects(() => verifyState(`${body}.${mac}`, secret), "bad_state");
  }
});
