import { assertEquals } from "@std/assert";
import type {
  IntegrityVerdict,
  PlayIntegrityDecoder,
  PlayIntegrityPayload,
} from "../_shared/integrity/play_integrity.ts";
import { evaluatePlayIntegrity } from "../_shared/integrity/play_integrity.ts";
import {
  type AppAttestDeps,
  type AppAttestKeyRecord,
  type AppAttestStore,
  type ConsumedNonce,
  createDeviceIntegrityHandler,
  type IntegrityStore,
  NonceRejectedError,
} from "./handler.ts";

const NOW = Date.UTC(2026, 8, 16, 12, 0, 0);
const NONCE = "n".repeat(43);
const PACKAGE = "com.suskii.errands";
const USER = "11111111-1111-4111-8111-111111111111";

console.log = () => {};
console.warn = () => {};
console.error = () => {};

function goodPayload(overrides: Partial<PlayIntegrityPayload> = {}): PlayIntegrityPayload {
  return {
    requestDetails: { requestPackageName: PACKAGE, nonce: NONCE, timestampMillis: String(NOW - 10_000) },
    appIntegrity: { appRecognitionVerdict: "PLAY_RECOGNIZED", packageName: PACKAGE },
    deviceIntegrity: { deviceRecognitionVerdict: ["MEETS_DEVICE_INTEGRITY"] },
    accountDetails: { appLicensingVerdict: "LICENSED" },
    environmentDetails: { playProtectVerdict: "NO_ISSUES" },
    ...overrides,
  };
}

const policy = { packageName: PACKAGE, maxAgeMs: 5 * 60_000 };

Deno.test("a genuine Play verdict passes", () => {
  const v = evaluatePlayIntegrity(goodPayload(), NONCE, policy, NOW);
  assertEquals([v.status, v.reasons], ["pass", []]);
});

Deno.test("each failed check is named", () => {
  const cases: [Partial<PlayIntegrityPayload>, string][] = [
    [{ requestDetails: { requestPackageName: "com.evil", nonce: NONCE, timestampMillis: NOW } }, "package_mismatch"],
    [{ requestDetails: { requestPackageName: PACKAGE, nonce: "other", timestampMillis: NOW } }, "nonce_mismatch"],
    [
      { requestDetails: { requestPackageName: PACKAGE, nonce: NONCE, timestampMillis: NOW - 301_000 } },
      "stale_verdict",
    ],
    [{ appIntegrity: { appRecognitionVerdict: "UNRECOGNIZED_VERSION" } }, "app_not_recognized"],
    [{ deviceIntegrity: { deviceRecognitionVerdict: [] } }, "device_integrity_failed"],
    [{ deviceIntegrity: { deviceRecognitionVerdict: ["MEETS_BASIC_INTEGRITY"] } }, "device_integrity_failed"],
    [{ deviceIntegrity: { deviceRecognitionVerdict: ["MEETS_VIRTUAL_INTEGRITY"] } }, "device_integrity_failed"],
    [{ accountDetails: { appLicensingVerdict: "UNLICENSED" } }, "app_not_licensed"],
  ];
  for (const [override, reason] of cases) {
    const v = evaluatePlayIntegrity(goodPayload(override), NONCE, policy, NOW);
    assertEquals(v.status, "fail", reason);
    assertEquals(v.reasons, [reason]);
  }
});

Deno.test("a verdict timestamped in the future beyond clock skew fails", () => {
  const v = evaluatePlayIntegrity(
    goodPayload({ requestDetails: { requestPackageName: PACKAGE, nonce: NONCE, timestampMillis: NOW + 120_000 } }),
    NONCE,
    policy,
    NOW,
  );
  assertEquals(v.reasons, ["stale_verdict"]);
});

class MemoryStore implements IntegrityStore {
  saved: { deviceId: string; userId: string; verdict: IntegrityVerdict }[] = [];
  constructor(private readonly nonce: ConsumedNonce | "reject") {}
  consumeNonce(_nonce: string, _userId: string): Promise<ConsumedNonce> {
    return this.nonce === "reject" ? Promise.reject(new NonceRejectedError()) : Promise.resolve(this.nonce);
  }
  saveVerdict(deviceId: string, userId: string, verdict: IntegrityVerdict): Promise<void> {
    this.saved.push({ deviceId, userId, verdict });
    return Promise.resolve();
  }
}

const decoderReturning = (p: PlayIntegrityPayload | Error): PlayIntegrityDecoder => ({
  decode: () => p instanceof Error ? Promise.reject(p) : Promise.resolve(p),
});

const post = (body: unknown) =>
  new Request("http://localhost/device-integrity", { method: "POST", body: JSON.stringify(body) });

const androidNonce: ConsumedNonce = { deviceId: "dev-1", purpose: "go_online", platform: "android" };

Deno.test("android: verifies the token and stores the verdict on the device", async () => {
  const store = new MemoryStore(androidNonce);
  const handler = createDeviceIntegrityHandler({
    store,
    playDecoder: decoderReturning(goodPayload()),
    androidPackageName: PACKAGE,
    now: () => NOW,
  });
  const res = await handler(post({ nonce: NONCE, token: "token" }), USER);
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { status: "pass", reasons: [], purpose: "go_online" });
  assertEquals(store.saved[0].deviceId, "dev-1");
  assertEquals(store.saved[0].userId, USER);
});

Deno.test("android: a token Google cannot decode is stored as a failure", async () => {
  const store = new MemoryStore(androidNonce);
  const handler = createDeviceIntegrityHandler({
    store,
    playDecoder: decoderReturning(new Error("play_integrity_decode_http_400")),
    androidPackageName: PACKAGE,
    now: () => NOW,
  });
  const body = await (await handler(post({ nonce: NONCE, token: "forged" }), USER)).json();
  assertEquals(body.status, "fail");
  assertEquals(store.saved[0].verdict.reasons, ["token_decode_failed"]);
});

Deno.test("android without credentials is recorded as unevaluated, never as a pass", async () => {
  const store = new MemoryStore(androidNonce);
  const body = await (await createDeviceIntegrityHandler({ store })(post({ nonce: NONCE, token: "t" }), USER)).json();
  assertEquals(body, { status: "unevaluated", reasons: ["play_integrity_not_configured"], purpose: "go_online" });
});

const iosNonce: ConsumedNonce = { deviceId: "dev-2", purpose: "payment", platform: "ios" };
const KEY_ID = btoa(String.fromCharCode(...new Uint8Array(32).fill(7)));
const TOKEN = btoa("apple-object");
const PUBLIC_KEY = new Uint8Array(65).fill(4);
const iosPolicy = {
  appId: "ABCDE12345.com.suskii.errands",
  environment: "production" as const,
  allowedValidationCategories: [4],
};

class MemoryAppAttestStore implements AppAttestStore {
  keys = new Map<string, { userId: string; deviceId: string; record: AppAttestKeyRecord }>();
  registerKey(input: Parameters<AppAttestStore["registerKey"]>[0]): Promise<boolean> {
    if (this.keys.has(input.keyId)) return Promise.resolve(false);
    this.keys.set(input.keyId, {
      userId: input.userId,
      deviceId: input.deviceId,
      record: { publicKey: input.publicKey, signCount: 0, environment: input.environment },
    });
    return Promise.resolve(true);
  }
  keyForAssertion(userId: string, deviceId: string, keyId: string): Promise<AppAttestKeyRecord | null> {
    const k = this.keys.get(keyId);
    return Promise.resolve(k && k.userId === userId && k.deviceId === deviceId ? { ...k.record } : null);
  }
  recordAssertion(userId: string, keyId: string, counter: number): Promise<boolean> {
    const k = this.keys.get(keyId);
    if (!k || k.userId !== userId || k.record.signCount >= counter) return Promise.resolve(false);
    k.record.signCount = counter;
    return Promise.resolve(true);
  }
}

async function nonceHash(): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(NONCE)));
}

function iosHandler(store: MemoryStore, attest: MemoryAppAttestStore, deps: Partial<AppAttestDeps> = {}) {
  return createDeviceIntegrityHandler({
    store,
    now: () => NOW,
    appAttest: {
      store: attest,
      policy: iosPolicy,
      verifyAttestation: async (_object, keyId, clientDataHash) => {
        // The handler binds the attestation to the consumed nonce and the key id sent.
        assertEquals(clientDataHash, await nonceHash());
        assertEquals(keyId.length, 32);
        return { ok: true, publicKey: PUBLIC_KEY, receipt: new Uint8Array([1]), extensions: { validationCategory: 4 } };
      },
      verifyAssertion: async (_object, clientDataHash, publicKey, previousCounter) => {
        assertEquals(clientDataHash, await nonceHash());
        assertEquals(publicKey, PUBLIC_KEY);
        return { ok: true, counter: previousCounter + 1, extensions: {} };
      },
      ...deps,
    },
  });
}

Deno.test("iOS: attestation stores the key, then assertions pass and advance the counter", async () => {
  const store = new MemoryStore(iosNonce);
  const attest = new MemoryAppAttestStore();
  const handler = iosHandler(store, attest);

  const attested =
    await (await handler(post({ nonce: NONCE, token: TOKEN, key_id: KEY_ID, kind: "attestation" }), USER))
      .json();
  assertEquals(attested, { status: "pass", reasons: [], purpose: "payment" });
  assertEquals(store.saved[0].verdict.signals?.validationCategory, 4);
  assertEquals(attest.keys.get(KEY_ID)?.deviceId, "dev-2");

  const asserted = await (await handler(post({ nonce: NONCE, token: TOKEN, key_id: KEY_ID, kind: "assertion" }), USER))
    .json();
  assertEquals(asserted.status, "pass");
  assertEquals(attest.keys.get(KEY_ID)?.record.signCount, 1);
});

Deno.test("iOS: a key attested twice, an unknown key and a lost counter race all fail", async () => {
  const store = new MemoryStore(iosNonce);
  const attest = new MemoryAppAttestStore();
  const handler = iosHandler(store, attest);
  const attestation = post({ nonce: NONCE, token: TOKEN, key_id: KEY_ID, kind: "attestation" });
  await handler(attestation, USER);
  const again = await (await handler(post({ nonce: NONCE, token: TOKEN, key_id: KEY_ID, kind: "attestation" }), USER))
    .json();
  assertEquals(again.reasons, ["app_attest_key_already_registered"]);

  const otherKey = btoa(String.fromCharCode(...new Uint8Array(32).fill(9)));
  const unknown = await (await handler(post({ nonce: NONCE, token: TOKEN, key_id: otherKey, kind: "assertion" }), USER))
    .json();
  assertEquals(unknown, { status: "fail", reasons: ["app_attest_key_unknown"], purpose: "payment" });

  const foreignUser =
    await (await handler(post({ nonce: NONCE, token: TOKEN, key_id: KEY_ID, kind: "assertion" }), "u2"))
      .json();
  assertEquals(foreignUser.reasons, ["app_attest_key_unknown"]);

  const replay = iosHandler(store, attest, {
    verifyAssertion: () => Promise.resolve({ ok: true, counter: 0, extensions: {} }),
  });
  const raced = await (await replay(post({ nonce: NONCE, token: TOKEN, key_id: KEY_ID, kind: "assertion" }), USER))
    .json();
  assertEquals(raced.reasons, ["counter_not_increasing"]);
});

Deno.test("iOS: verification failures are stored as failures with Apple's reason", async () => {
  const store = new MemoryStore(iosNonce);
  const attest = new MemoryAppAttestStore();
  const handler = iosHandler(store, attest, {
    verifyAttestation: () => Promise.resolve({ ok: false, reason: "certificate_chain_invalid" }),
  });
  const body = await (await handler(post({ nonce: NONCE, token: TOKEN, key_id: KEY_ID, kind: "attestation" }), USER))
    .json();
  assertEquals(body, { status: "fail", reasons: ["certificate_chain_invalid"], purpose: "payment" });
  assertEquals(attest.keys.size, 0);

  const notBase64 =
    await (await handler(post({ nonce: NONCE, token: "%%%", key_id: KEY_ID, kind: "attestation" }), USER))
      .json();
  assertEquals(notBase64.reasons, ["attestation_malformed"]);
});

Deno.test("iOS: requests without key_id and kind are refused; unconfigured App Attest is unevaluated", async () => {
  const store = new MemoryStore(iosNonce);
  const handler = iosHandler(store, new MemoryAppAttestStore());
  assertEquals((await handler(post({ nonce: NONCE, token: TOKEN }), USER)).status, 400);
  assertEquals(
    (await handler(post({ nonce: NONCE, token: TOKEN, key_id: "c2hvcnQ=", kind: "assertion" }), USER)).status,
    400,
  );
  assertEquals((await handler(post({ nonce: NONCE, token: TOKEN, key_id: KEY_ID, kind: "other" }), USER)).status, 400);

  const unconfigured = await (await createDeviceIntegrityHandler({ store })(
    post({ nonce: NONCE, token: TOKEN, key_id: KEY_ID, kind: "attestation" }),
    USER,
  )).json();
  assertEquals(unconfigured, { status: "unevaluated", reasons: ["app_attest_not_configured"], purpose: "payment" });
});

Deno.test("iOS: a store error is a 500, not a verdict", async () => {
  const store = new MemoryStore(iosNonce);
  const attest = new MemoryAppAttestStore();
  attest.registerKey = () => Promise.reject(new Error("db down"));
  const res = await iosHandler(store, attest)(
    post({ nonce: NONCE, token: TOKEN, key_id: KEY_ID, kind: "attestation" }),
    USER,
  );
  assertEquals(res.status, 500);
  assertEquals(store.saved.length, 0);
});

Deno.test("a rejected nonce stores nothing", async () => {
  const store = new MemoryStore("reject");
  const res = await createDeviceIntegrityHandler({ store })(post({ nonce: NONCE, token: "t" }), USER);
  assertEquals(res.status, 400);
  assertEquals((await res.json()).error.code, "ERR_INTEGRITY_NONCE_INVALID");
  assertEquals(store.saved.length, 0);
});

Deno.test("malformed requests are refused", async () => {
  const handler = createDeviceIntegrityHandler({ store: new MemoryStore(androidNonce) });
  assertEquals((await handler(post({ nonce: "short", token: "t" }), USER)).status, 400);
  assertEquals((await handler(post({ nonce: NONCE }), USER)).status, 400);
  assertEquals((await handler(new Request("http://localhost", { method: "GET" }), USER)).status, 405);
});
