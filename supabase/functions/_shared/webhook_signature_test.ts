import { assert, assertEquals } from "./test_helpers.ts";
import { createWebhookVerifier, KEYSET_URL } from "./webhook_signature.ts";
import { encodeBase64, signatureFixture } from "./webhook_test_helpers.ts";

Deno.test("webhook signatures verify real P-256 signatures, padding and short coordinates", async () => {
  const body = new TextEncoder().encode('{"data":{"operation":"UPSERT"}}');
  for (const mode of ["normal", "padded", "short"] as const) {
    const fixture = await signatureFixture(0xf1234567, mode);
    const verify = createWebhookVerifier((url) => {
      assertEquals(String(url), KEYSET_URL);
      return Promise.resolve(Response.json(fixture.keyset));
    });
    const signature = await fixture.sign(body);
    assert(await verify(body, signature));
    assert(!await verify(new TextEncoder().encode("tampered"), signature));
  }
});

Deno.test("webhook keyset cache lasts one hour and unknown keys trigger one refetch", async () => {
  const first = await signatureFixture(1);
  const rotated = await signatureFixture(2);
  const body = new TextEncoder().encode("body");
  let calls = 0;
  let now = 0;
  let keyset = first.keyset;
  const verify = createWebhookVerifier(() => {
    calls++;
    return Promise.resolve(Response.json(keyset));
  }, () => now);
  assert(await verify(body, await first.sign(body)));
  assert(await verify(body, await first.sign(body)));
  assertEquals(calls, 1);
  keyset = rotated.keyset;
  assert(await verify(body, await rotated.sign(body)));
  assertEquals(calls, 2);
  assert(!await verify(body, await rotated.sign(body, 3)));
  assertEquals(calls, 3);
  now = 3600000;
  assert(await verify(body, await rotated.sign(body)));
  assertEquals(calls, 4);
});

Deno.test("webhook signatures reject malformed prefixes, base64, DER and unavailable keys", async () => {
  const fixture = await signatureFixture();
  const body = new TextEncoder().encode("body");
  let fetches = 0;
  const verify = createWebhookVerifier(() => {
    fetches++;
    return Promise.resolve(Response.json(fixture.keyset));
  });
  for (const header of [null, "", "not-base64!", "AAAA", "====", "AA==junk"]) {
    assert(!await verify(body, header));
  }
  const signed = Uint8Array.from(atob(await fixture.sign(body)), (char) => char.charCodeAt(0));
  for (const offset of [0, 5, 6, 7, 8]) {
    const bad = signed.slice();
    bad[offset] = 0xff;
    assert(!await verify(body, encodeBase64(bad)));
  }
  assertEquals(fetches, 0);
  const disabled = structuredClone(fixture.keyset);
  disabled.key[0].status = "DISABLED";
  assert(
    !await createWebhookVerifier(() => Promise.resolve(Response.json(disabled)))(
      body,
      await fixture.sign(body),
    ),
  );
  assert(
    !await createWebhookVerifier(() => Promise.resolve(new Response(null, { status: 503 })))(
      body,
      await fixture.sign(body),
    ),
  );
});
