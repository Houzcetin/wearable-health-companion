// Synthetic keys and signatures only. Never contacts Google.
export function encodeBase64(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes));
}
function derInteger(bytes: Uint8Array): number[] {
  let value = bytes;
  while (value.length > 1 && value[0] === 0) value = value.slice(1);
  const encoded = value[0] & 128 ? [0, ...value] : [...value];
  return [2, encoded.length, ...encoded];
}

export async function signatureFixture(
  keyId = 1234,
  mode: "normal" | "padded" | "short" = "normal",
) {
  let pair: CryptoKeyPair;
  let point: Uint8Array;
  do {
    pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, [
      "sign",
      "verify",
    ]);
    point = new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey));
  } while (mode === "short" && point[1] !== 0 && point[33] !== 0);
  function coordinate(bytes: Uint8Array): number[] {
    if (mode === "padded") return [0, ...bytes];
    if (mode === "short") {
      while (bytes.length > 1 && bytes[0] === 0) bytes = bytes.slice(1);
    }
    return [...bytes];
  }
  const x = coordinate(point.slice(1, 33));
  const y = coordinate(point.slice(33));
  // Include params (field 2) and version (field 1) to exercise skipping unknown fields.
  const protobuf = new Uint8Array([8, 0, 18, 2, 8, 2, 26, x.length, ...x, 34, y.length, ...y]);
  const keyset = {
    primaryKeyId: keyId,
    key: [{
      keyData: {
        typeUrl: "type.googleapis.com/google.crypto.tink.EcdsaPublicKey",
        value: encodeBase64(protobuf),
        keyMaterialType: "ASYMMETRIC_PUBLIC",
      },
      status: "ENABLED",
      keyId,
      outputPrefixType: "TINK",
    }],
  };
  async function sign(body: Uint8Array<ArrayBuffer>, signingId = keyId): Promise<string> {
    const raw = new Uint8Array(
      await crypto.subtle.sign(
        { name: "ECDSA", hash: "SHA-256" },
        pair.privateKey,
        body,
      ),
    );
    const integers = [...derInteger(raw.slice(0, 32)), ...derInteger(raw.slice(32))];
    const prefix = new Uint8Array(5);
    prefix[0] = 1;
    new DataView(prefix.buffer).setUint32(1, signingId, false);
    return encodeBase64(new Uint8Array([...prefix, 0x30, integers.length, ...integers]));
  }
  return { keyset, sign };
}
