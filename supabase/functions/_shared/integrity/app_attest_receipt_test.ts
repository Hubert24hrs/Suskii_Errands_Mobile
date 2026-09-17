import { assert, assertEquals } from "@std/assert";
import { APPLE_APP_ATTEST_ROOT_PEM, verifyAttestation } from "./app_attest.ts";
import { APPLE_ROOT_CA_G3_PEM, verifyReceipt } from "./app_attest_receipt.ts";
import { pemToDer } from "./der.ts";
import vectors from "./testdata/app_attest_vectors.json" with { type: "json" };

const b64 = (s: string) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
const hex = (b: Uint8Array) => Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");
const ios = vectors.ios_14_4;
const iosKey = b64(ios.public_key_spki_base64).slice(-65);
const at = (iso: string, plusMs = 0) => new Date(new Date(iso).getTime() + plusMs);

Deno.test("pinned receipt root is Apple Root CA - G3", async () => {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", pemToDer(APPLE_ROOT_CA_G3_PEM)));
  assertEquals(hex(digest).toUpperCase(), "63343ABFB89A6A03EBB57E9B3F5FA7BE7C4F5C756F3017B3A8C488C3653E9179");
});

Deno.test("the receipt inside Apple's sample attestation verifies", async () => {
  const g = vectors.apple_guide;
  const attestation = await verifyAttestation(
    b64(g.attestation_base64),
    b64(g.key_id_base64),
    new TextEncoder().encode(g.client_data),
    { appId: g.app_id, environment: "production", allowedValidationCategories: [1] },
    new Date(g.valid_at),
  );
  assert(attestation.ok);
  const created = "2026-04-21T18:13:12.153Z";
  const outcome = await verifyReceipt(attestation.receipt, {
    appId: g.app_id,
    publicKey: attestation.publicKey,
    now: at(created, 30_000),
  });
  assert(outcome.ok, JSON.stringify(outcome));
  assertEquals(outcome.receipt.type, "ATTEST");
  assertEquals(outcome.receipt.creationTime.toISOString(), created);
});

Deno.test("real device receipts: attestation receipt, and a refreshed receipt with the risk metric", async () => {
  const attest = await verifyReceipt(b64(ios.attest_receipt_base64), {
    appId: ios.app_id,
    publicKey: iosKey,
    now: at(ios.attest_receipt_created_at, 60_000),
  });
  assert(attest.ok, JSON.stringify(attest));
  assertEquals([attest.receipt.type, attest.receipt.riskMetric], ["ATTEST", undefined]);

  const refreshed = await verifyReceipt(b64(ios.refreshed_receipt_base64), {
    appId: ios.app_id,
    publicKey: iosKey,
    now: at(ios.refreshed_receipt_created_at, 60_000),
  });
  assert(refreshed.ok, JSON.stringify(refreshed));
  assertEquals(refreshed.receipt.type, "RECEIPT");
  assertEquals(refreshed.receipt.riskMetric, ios.refreshed_receipt_risk_metric);
  assertEquals(refreshed.receipt.notBefore?.toISOString(), "2021-01-24T12:26:41.564Z");
  assertEquals(refreshed.receipt.expirationTime?.toISOString(), "2021-04-23T12:26:41.564Z");
});

Deno.test("receipts: each failed check is named", async () => {
  const receipt = b64(ios.refreshed_receipt_base64);
  const now = at(ios.refreshed_receipt_created_at, 60_000);
  const expected = { appId: ios.app_id, publicKey: iosKey, now };

  const tampered = receipt.slice();
  tampered[100] ^= 0x01; // inside the signed App ID field
  const otherKey = iosKey.slice();
  otherKey[64] ^= 0x01;

  const cases: [Promise<{ ok: boolean; reason?: string }>, string][] = [
    [verifyReceipt(tampered, expected), "receipt_signature_invalid"],
    [verifyReceipt(receipt, { ...expected, appId: "6MURL8TA57.com.evil" }), "receipt_app_id_mismatch"],
    [
      verifyReceipt(receipt, { ...expected, now: at(ios.refreshed_receipt_created_at, 5 * 60_000 + 1) }),
      "receipt_stale",
    ],
    [verifyReceipt(receipt, { ...expected, now: at(ios.refreshed_receipt_created_at, -61_000) }), "receipt_stale"],
    [verifyReceipt(receipt, { ...expected, publicKey: otherKey }), "receipt_public_key_mismatch"],
    // The signing certificate expired on 2021-06-18.
    [
      verifyReceipt(receipt, { ...expected, now: new Date("2021-07-01T00:00:00Z"), maxAgeMs: 1e12 }),
      "receipt_chain_invalid",
    ],
    [verifyReceipt(receipt, expected, APPLE_APP_ATTEST_ROOT_PEM), "receipt_chain_invalid"],
    [verifyReceipt(receipt.slice(0, 2000), expected), "receipt_malformed"],
    [verifyReceipt(new TextEncoder().encode("not a receipt"), expected), "receipt_malformed"],
  ];
  for (const [promise, reason] of cases) {
    const result = await promise;
    assertEquals([result.ok, result.reason], [false, reason]);
  }
});
