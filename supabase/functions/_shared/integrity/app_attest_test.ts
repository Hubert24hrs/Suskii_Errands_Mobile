import { assert, assertEquals, assertThrows } from "@std/assert";
import {
  type AppAttestPolicy,
  APPLE_APP_ATTEST_ROOT_PEM,
  sha256,
  verifyAssertion,
  verifyAttestation,
} from "./app_attest.ts";
import { decodeCbor } from "./cbor.ts";
import { ecdsaDerToRaw, parseCertificate, pemToDer } from "./der.ts";
import vectors from "./testdata/app_attest_vectors.json" with { type: "json" };

// Apple's published sample (validation guide) and a real iOS 14.4 device capture; sources are
// recorded in the fixture file.

const guide = vectors.apple_guide;
const ios = vectors.ios_14_4;

const b64 = (s: string) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
const utf8 = (s: string) => new TextEncoder().encode(s);
const hex = (b: Uint8Array) => Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");

// Apple's sample passes the challenge bytes themselves as clientDataHash.
const guideArgs = () =>
  [
    b64(guide.attestation_base64),
    b64(guide.key_id_base64),
    utf8(guide.client_data),
    { appId: guide.app_id, environment: "production", allowedValidationCategories: [1] } as AppAttestPolicy,
    new Date(guide.valid_at),
  ] as const;

const iosPolicy: AppAttestPolicy = { appId: ios.app_id, environment: "development", allowedValidationCategories: [3] };
const iosClientDataHash = async () => await sha256(b64(ios.client_data_base64));

Deno.test("pinned root is Apple's App Attestation Root CA", async () => {
  const der = pemToDer(APPLE_APP_ATTEST_ROOT_PEM);
  assertEquals(
    hex(new Uint8Array(await crypto.subtle.digest("SHA-256", der))).toUpperCase(),
    "1CB9823BA28BA6AD2D33A006941DE2AE4F513EF1D4E831B9F7E0FA7B6242C932",
  );
  const root = parseCertificate(der);
  assertEquals(root.notAfter.toISOString(), "2045-03-15T00:00:00.000Z");
});

Deno.test("Apple's sample attestation verifies, with its extensions", async () => {
  const result = await verifyAttestation(...guideArgs());
  assert(result.ok, JSON.stringify(result));
  assertEquals(result.extensions.validationCategory, 1);
  assertEquals(typeof result.extensions.bundleVersion, "string");
  assertEquals(await sha256(result.publicKey), b64(guide.key_id_base64));
  assert(result.receipt.length > 0);
});

Deno.test("Apple's sample: every changed input is refused with its own reason", async () => {
  const [object, keyId, hash, policy, now] = guideArgs();
  const tampered = object.slice();
  tampered[tampered.length - 1] ^= 0xff; // last byte of authData (the validation category) → nonce no longer matches
  const otherKey = keyId.slice();
  otherKey[0] ^= 1;
  const cases: [Promise<{ ok: boolean; reason?: string }>, string][] = [
    [verifyAttestation(object, keyId, utf8("another_challenge"), policy, now), "nonce_mismatch"],
    [verifyAttestation(tampered, keyId, hash, policy, now), "nonce_mismatch"],
    [verifyAttestation(object, otherKey, hash, policy, now), "key_id_mismatch"],
    [verifyAttestation(object, keyId, hash, { ...policy, appId: "1234567890.com.evil.app" }, now), "app_id_mismatch"],
    [verifyAttestation(object, keyId, hash, { ...policy, environment: "development" }, now), "environment_mismatch"],
    [
      verifyAttestation(object, keyId, hash, { ...policy, allowedValidationCategories: [4] }, now),
      "validation_category_not_allowed",
    ],
    [verifyAttestation(object, keyId, hash, policy, new Date("2026-05-01T00:00:00Z")), "certificate_chain_invalid"],
    [verifyAttestation(object, keyId, hash, policy, new Date("2026-04-19T00:00:00Z")), "certificate_chain_invalid"],
    [verifyAttestation(utf8("not cbor at all"), keyId, hash, policy, now), "attestation_malformed"],
  ];
  for (const [promise, reason] of cases) {
    const result = await promise;
    assertEquals([result.ok, result.reason], [false, reason]);
  }
});

Deno.test("a chain that does not end at the pinned root is refused", async () => {
  const [object, keyId, hash, policy, now] = guideArgs();
  // A real Apple CA, but not the App Attestation root: the intermediate is not signed by it.
  const intermediateAsRoot = await verifyAttestation(object, keyId, hash, policy, now, OTHER_APPLE_ROOT_G3);
  assertEquals([intermediateAsRoot.ok, (intermediateAsRoot as { reason: string }).reason], [
    false,
    "certificate_chain_invalid",
  ]);
});

Deno.test("real iOS 14.4 attestation and assertion verify in the development environment", async () => {
  const attestation = await verifyAttestation(
    b64(ios.attestation_base64),
    b64(ios.key_id_base64),
    await iosClientDataHash(),
    iosPolicy,
    new Date(ios.valid_at),
  );
  assert(attestation.ok, JSON.stringify(attestation));
  assertEquals(attestation.extensions, {}); // iOS 14.4 predates the extensions: accepted without them
  // The stored key is the uncompressed point at the end of the published SPKI.
  assertEquals(attestation.publicKey, b64(ios.public_key_spki_base64).slice(-65));

  const assertion = await verifyAssertion(
    b64(ios.assertion_base64),
    await sha256(b64(ios.assertion_client_data_base64)),
    attestation.publicKey,
    0,
    iosPolicy,
  );
  assertEquals(assertion, { ok: true, counter: ios.assertion_counter, extensions: {} });
});

Deno.test("real iOS assertion: replay, wrong data, wrong key and wrong app are refused", async () => {
  const publicKey = b64(ios.public_key_spki_base64).slice(-65);
  const object = b64(ios.assertion_base64);
  const hash = await sha256(b64(ios.assertion_client_data_base64));
  const otherKey = new Uint8Array(
    await crypto.subtle.exportKey(
      "raw",
      (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign"])).publicKey,
    ),
  );
  const cases: [Promise<{ ok: boolean; reason?: string }>, string][] = [
    [verifyAssertion(object, hash, publicKey, ios.assertion_counter, iosPolicy), "counter_not_increasing"],
    [verifyAssertion(object, await sha256(utf8("other")), publicKey, 0, iosPolicy), "signature_invalid"],
    [verifyAssertion(object, hash, otherKey, 0, iosPolicy), "signature_invalid"],
    [verifyAssertion(object, hash, publicKey, 0, { ...iosPolicy, appId: "6MURL8TA57.com.evil" }), "app_id_mismatch"],
    [verifyAssertion(utf8("garbage"), hash, publicKey, 0, iosPolicy), "assertion_malformed"],
  ];
  for (const [promise, reason] of cases) {
    const result = await promise;
    assertEquals([result.ok, result.reason], [false, reason]);
  }
});

Deno.test("assertion extensions: validation category is enforced when present", async () => {
  const appId = "ABCDE12345.com.suskii.errands";
  const keys = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const publicKey = new Uint8Array(await crypto.subtle.exportKey("raw", keys.publicKey));
  const clientDataHash = await sha256(utf8("nonce-from-request_integrity_nonce"));

  const build = async (category: number) => {
    const name = utf8("apple_validation_category_01");
    const extensions = new Uint8Array([0xa1, 0x78, name.length, ...name, 0x44, category, 0, 0, 0]);
    const authData = new Uint8Array([...await sha256(utf8(appId)), 0x40, 0, 0, 0, 7, ...extensions]);
    const nonce = await sha256(authData, clientDataHash);
    const p1363 = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, keys.privateKey, nonce));
    const signature = rawToDer(p1363);
    return cborMap([["signature", signature], ["authenticatorData", authData]]);
  };

  const policy: AppAttestPolicy = { appId, environment: "production", allowedValidationCategories: [4] };
  assertEquals(await verifyAssertion(await build(4), clientDataHash, publicKey, 6, policy), {
    ok: true,
    counter: 7,
    extensions: { validationCategory: 4 },
  });
  assertEquals(await verifyAssertion(await build(3), clientDataHash, publicKey, 6, policy), {
    ok: false,
    reason: "validation_category_not_allowed",
  });
});

Deno.test("CBOR decoder refuses what App Attest never sends", () => {
  assertEquals(decodeCbor(new Uint8Array([0xa1, 0x61, 0x61, 0x42, 1, 2])), new Map([["a", new Uint8Array([1, 2])]]));
  assertThrows(() => decodeCbor(new Uint8Array([0x5f, 0x41, 0x00, 0xff]))); // indefinite length
  assertThrows(() => decodeCbor(new Uint8Array([0x01, 0x02]))); // trailing bytes
  assertThrows(() => decodeCbor(new Uint8Array([0xa2, 0x61, 0x61, 0x01, 0x61, 0x61, 0x02]))); // duplicate key
  assertThrows(() => decodeCbor(new Uint8Array([0x5a, 0xff, 0xff, 0xff, 0xff]))); // length past the end
  assertThrows(() => decodeCbor(new Uint8Array(40).fill(0x81))); // nesting too deep
});

Deno.test("ECDSA DER signatures convert to fixed-width r || s", () => {
  // r = 0x00 0x80 (leading zero for sign), s = 0x01
  const der = new Uint8Array([0x30, 0x07, 0x02, 0x02, 0x00, 0x80, 0x02, 0x01, 0x01]);
  const raw = ecdsaDerToRaw(der, 32);
  assertEquals(raw.length, 64);
  assertEquals([raw[31], raw[63]], [0x80, 0x01]);
  assertThrows(() => ecdsaDerToRaw(new Uint8Array([...der, 0]), 32));
});

function rawToDer(p1363: Uint8Array): Uint8Array {
  const int = (bytes: Uint8Array) => {
    let i = 0;
    while (i < bytes.length - 1 && bytes[i] === 0) i++;
    const trimmed = bytes.subarray(i);
    const body = trimmed[0] & 0x80 ? new Uint8Array([0, ...trimmed]) : trimmed;
    return [0x02, body.length, ...body];
  };
  const body = [...int(p1363.subarray(0, 32)), ...int(p1363.subarray(32))];
  return new Uint8Array([0x30, body.length, ...body]);
}

function cborMap(entries: [string, Uint8Array][]): Uint8Array {
  const out: number[] = [0xa0 + entries.length];
  const head = (major: number, length: number) =>
    length < 24 ? [major | length] : length < 256 ? [major | 24, length] : [major | 25, length >> 8, length & 0xff];
  for (const [key, value] of entries) {
    const k = utf8(key);
    out.push(...head(0x60, k.length), ...k, ...head(0x40, value.length), ...value);
  }
  return new Uint8Array(out);
}

// Apple Root CA - G3 (www.apple.com/certificateauthority/AppleRootCA-G3.cer, fetched 2026-09-17):
// a genuine Apple root that must not be accepted in place of the App
// Attestation root.
const OTHER_APPLE_ROOT_G3 = `-----BEGIN CERTIFICATE-----
MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwS
QXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9u
IEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcN
MTQwNDMwMTgxOTA2WhcNMzkwNDMwMTgxOTA2WjBnMRswGQYDVQQDDBJBcHBsZSBS
b290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRpb24gQXV0aG9y
aXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqGSM49
AgEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtf
TjjTuxxEtX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dvMVztK517
IDvYuVTZXpmkOlEKMaNCMEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySr
MA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMDA2gA
MGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3meoyhpmvOwgPUnPWTxnS4
at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkLF1vLUagM
6BgD56KyKA==
-----END CERTIFICATE-----`;
