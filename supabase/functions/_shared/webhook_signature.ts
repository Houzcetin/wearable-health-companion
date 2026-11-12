import { record } from "./google.ts";
import { timedFetch } from "./supabase.ts";

export const KEYSET_URL =
  "https://www.gstatic.com/googlehealthapi/webhooks/webhooks_public_keyset.json";
const CACHE_MS = 60 * 60 * 1000;

function base64(value: string): Uint8Array<ArrayBuffer> {
  if (!value || value.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(value)) {
    throw new Error("invalid_base64");
  }
  return Uint8Array.from(atob(value), (char) => char.charCodeAt(0));
}

// UNVERIFIED: check the real keyset protobuf field layout against a live notification.
function publicPoint(bytes: Uint8Array): Uint8Array<ArrayBuffer> {
  let offset = 0;
  const coordinates = new Map<number, Uint8Array>();
  function varint(): number {
    let value = 0;
    for (let shift = 0; shift < 35; shift += 7) {
      if (offset >= bytes.length) throw new Error("invalid_protobuf");
      const byte = bytes[offset++];
      value += (byte & 127) * 2 ** shift;
      if (byte < 128) return value;
    }
    throw new Error("invalid_protobuf");
  }
  while (offset < bytes.length) {
    const tag = varint();
    const field = Math.floor(tag / 8);
    const wire = tag % 8;
    if (!field) throw new Error("invalid_protobuf");
    if (wire === 0) varint();
    else if (wire === 1) offset += 8;
    else if (wire === 5) offset += 4;
    else if (wire === 2) {
      const size = varint();
      if (size > bytes.length - offset) throw new Error("invalid_protobuf");
      if (field === 3 || field === 4) {
        if (coordinates.has(field)) throw new Error("invalid_protobuf");
        coordinates.set(field, bytes.slice(offset, offset + size));
      }
      offset += size;
    } else throw new Error("invalid_protobuf");
    if (offset > bytes.length) throw new Error("invalid_protobuf");
  }
  const point = new Uint8Array(65);
  point[0] = 4;
  for (const [field, start] of [[3, 1], [4, 33]]) {
    let value = coordinates.get(field);
    if (!value?.length) throw new Error("invalid_coordinate");
    while (value.length > 32 && value[0] === 0) value = value.slice(1);
    if (value.length > 32) throw new Error("invalid_coordinate");
    point.set(value, start + 32 - value.length);
  }
  return point;
}

function rawSignature(der: Uint8Array): Uint8Array<ArrayBuffer> {
  // P-256 DER sequences fit in a canonical single-byte length (at most 72 bytes).
  if (der[0] !== 0x30 || der[1] !== der.length - 2 || der.length > 72) {
    throw new Error("invalid_der");
  }
  let offset = 2;
  const raw = new Uint8Array(64);
  for (const start of [0, 32]) {
    if (der[offset++] !== 2) throw new Error("invalid_der");
    const size = der[offset++];
    if (!size || size > 33 || offset + size > der.length) throw new Error("invalid_der");
    let value = der.slice(offset, offset + size);
    offset += size;
    if (value[0] & 128) throw new Error("invalid_der");
    if (value.length > 1 && value[0] === 0) {
      if (!(value[1] & 128)) throw new Error("invalid_der");
      value = value.slice(1);
    }
    if (value.length > 32) throw new Error("invalid_der");
    raw.set(value, start + 32 - value.length);
  }
  if (offset !== der.length) throw new Error("invalid_der");
  return raw;
}

export function createWebhookVerifier(fetcher: typeof fetch = timedFetch, now = Date.now) {
  let keys = new Map<number, CryptoKey>();
  let expiresAt = 0;
  async function refresh(): Promise<void> {
    const response = await fetcher(KEYSET_URL);
    if (!response.ok) throw new Error("keyset_unavailable");
    const body = record(await response.json());
    if (!Array.isArray(body.key)) throw new Error("invalid_keyset");
    const next = new Map<number, CryptoKey>();
    for (const entry of body.key) {
      const item = record(entry);
      const data = record(item.keyData);
      if (
        item.status !== "ENABLED" || item.outputPrefixType !== "TINK" ||
        data.keyMaterialType !== "ASYMMETRIC_PUBLIC" ||
        typeof data.typeUrl !== "string" || !data.typeUrl.endsWith(".EcdsaPublicKey") ||
        typeof data.value !== "string" || typeof item.keyId !== "number" ||
        !Number.isInteger(item.keyId) || item.keyId < 0 || item.keyId > 0xffffffff
      ) continue;
      const key = await crypto.subtle.importKey(
        "raw",
        publicPoint(base64(data.value)),
        { name: "ECDSA", namedCurve: "P-256" },
        false,
        ["verify"],
      );
      next.set(item.keyId, key);
    }
    keys = next;
    expiresAt = now() + CACHE_MS;
  }
  return async (body: Uint8Array<ArrayBuffer>, header: string | null): Promise<boolean> => {
    try {
      const signed = base64(header ?? "");
      if (signed.length < 13 || signed[0] !== 1) return false;
      const keyId = new DataView(signed.buffer).getUint32(1, false);
      const signature = rawSignature(signed.slice(5));
      if (now() >= expiresAt) await refresh();
      if (!keys.has(keyId)) await refresh();
      const key = keys.get(keyId);
      return !!key && await crypto.subtle.verify(
        { name: "ECDSA", hash: "SHA-256" },
        key,
        signature,
        body,
      );
    } catch {
      return false;
    }
  };
}

// One warm Edge Function isolate keeps its keyset for an hour.
export const verifyWebhookSignature = createWebhookVerifier();
