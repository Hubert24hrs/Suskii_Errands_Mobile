import { assertEquals } from "@std/assert";
import type {
  IntegrityVerdict,
  PlayIntegrityDecoder,
  PlayIntegrityPayload,
} from "../_shared/integrity/play_integrity.ts";
import { evaluatePlayIntegrity } from "../_shared/integrity/play_integrity.ts";
import {
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

Deno.test("iOS is unevaluated until App Attest verification exists", async () => {
  const store = new MemoryStore({ deviceId: "dev-2", purpose: "payment", platform: "ios" });
  const body = await (await createDeviceIntegrityHandler({ store })(post({ nonce: NONCE, token: "t" }), USER)).json();
  assertEquals(body.status, "unevaluated");
  assertEquals(body.reasons, ["app_attest_not_implemented"]);
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
