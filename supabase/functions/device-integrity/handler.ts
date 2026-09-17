// Device integrity verification (PRD SH-38; threat model §1; spec phase 2).
// Flow: app calls request_integrity_nonce(device, purpose) → obtains a Play Integrity token, or
// an App Attest attestation/assertion with clientDataHash = SHA-256(nonce), for that nonce →
// POSTs { nonce, token } (iOS adds { key_id, kind }) here with the user's JWT → the nonce is
// consumed for this user → the token is verified → the verdict is stored on the device row,
// where money, referral and go-online checks read it.
//
// iOS: `kind: "attestation"` once per App Attest key (the key is then stored); every later
// sensitive action sends `kind: "assertion"` with the same key_id. A verdict with reason
// `app_attest_key_unknown` tells the app to generate and attest a new key.

import { errorResponse, json } from "../_shared/http.ts";
import { log } from "../_shared/log.ts";
import { type AppAttestPolicy, sha256, verifyAssertion, verifyAttestation } from "../_shared/integrity/app_attest.ts";
import { verifyReceipt } from "../_shared/integrity/app_attest_receipt.ts";
import {
  evaluatePlayIntegrity,
  type IntegrityVerdict,
  type PlayIntegrityDecoder,
} from "../_shared/integrity/play_integrity.ts";

export interface ConsumedNonce {
  deviceId: string;
  purpose: string;
  platform: "android" | "ios" | "web";
}

export interface IntegrityStore {
  /** Throws NonceRejectedError when the nonce is unknown, foreign, expired or used. */
  consumeNonce(nonce: string, userId: string): Promise<ConsumedNonce>;
  saveVerdict(deviceId: string, userId: string, verdict: IntegrityVerdict): Promise<void>;
}

export class NonceRejectedError extends Error {}

export interface AppAttestKeyRecord {
  /** Base64 X9.62 uncompressed point. */
  publicKey: string;
  signCount: number;
  environment: string;
}

export interface AppAttestStore {
  /** False when the key id is already registered to anyone. */
  registerKey(input: {
    userId: string;
    deviceId: string;
    keyId: string;
    publicKey: string;
    receipt: string;
    receiptExpiresAt?: string;
    environment: string;
    validationCategory?: number;
    bundleVersion?: string;
  }): Promise<boolean>;
  keyForAssertion(userId: string, deviceId: string, keyId: string): Promise<AppAttestKeyRecord | null>;
  /** False when the counter is not higher than the stored one. */
  recordAssertion(userId: string, keyId: string, counter: number): Promise<boolean>;
}

export interface AppAttestDeps {
  store: AppAttestStore;
  policy: AppAttestPolicy;
  verifyAttestation?: typeof verifyAttestation;
  verifyAssertion?: typeof verifyAssertion;
  verifyReceipt?: typeof verifyReceipt;
}

export interface DeviceIntegrityDeps {
  store: IntegrityStore;
  /** Undefined when Play Integrity credentials are not configured for this environment. */
  playDecoder?: PlayIntegrityDecoder;
  androidPackageName?: string;
  /** Undefined when the iOS App ID is not configured for this environment. */
  appAttest?: AppAttestDeps;
  maxVerdictAgeMs?: number;
  now?: () => number;
}

interface RequestBody {
  nonce?: unknown;
  token?: unknown;
  key_id?: unknown;
  kind?: unknown;
}

const BASE64 = /^[A-Za-z0-9+/]+={0,2}$/;

function decodeBase64(value: string): Uint8Array | null {
  if (!BASE64.test(value) || value.length % 4 !== 0) return null;
  try {
    return Uint8Array.from(atob(value), (c) => c.charCodeAt(0));
  } catch {
    return null;
  }
}

export function createDeviceIntegrityHandler(deps: DeviceIntegrityDeps) {
  const now = deps.now ?? Date.now;

  return async (req: Request, userId: string): Promise<Response> => {
    if (req.method !== "POST") return errorResponse(405, "ERR_METHOD_NOT_ALLOWED");

    let body: RequestBody;
    try {
      body = await req.json();
    } catch {
      return errorResponse(400, "ERR_INVALID_ARGUMENT");
    }
    if (
      typeof body.nonce !== "string" || body.nonce.length < 16 || body.nonce.length > 500 ||
      typeof body.token !== "string" || body.token.length === 0 || body.token.length > 20_000
    ) {
      return errorResponse(400, "ERR_INVALID_ARGUMENT");
    }
    const keyId = typeof body.key_id === "string" ? decodeBase64(body.key_id) : null;
    if (
      (body.key_id !== undefined && keyId?.length !== 32) ||
      (body.kind !== undefined && body.kind !== "attestation" && body.kind !== "assertion")
    ) {
      return errorResponse(400, "ERR_INVALID_ARGUMENT");
    }

    let consumed: ConsumedNonce;
    try {
      consumed = await deps.store.consumeNonce(body.nonce, userId);
    } catch (err) {
      if (err instanceof NonceRejectedError) return errorResponse(400, "ERR_INTEGRITY_NONCE_INVALID");
      log("error", "device_integrity.nonce_store_error", { error: String(err) });
      return errorResponse(500, "ERR_INTERNAL");
    }

    let verdict: IntegrityVerdict;
    if (consumed.platform === "android") {
      if (!deps.playDecoder || !deps.androidPackageName) {
        verdict = unevaluated("android", "play_integrity_not_configured", now());
      } else {
        try {
          const payload = await deps.playDecoder.decode(deps.androidPackageName, body.token);
          verdict = evaluatePlayIntegrity(payload, body.nonce, {
            packageName: deps.androidPackageName,
            maxAgeMs: deps.maxVerdictAgeMs ?? 5 * 60_000,
          }, now());
        } catch (err) {
          // A token Google cannot decode is treated as failed, not unevaluated: forged or
          // replayed tokens land here.
          log("warn", "device_integrity.decode_failed", { error: String(err) });
          verdict = {
            status: "fail",
            platform: "android",
            reasons: ["token_decode_failed"],
            checkedAt: new Date(now()).toISOString(),
          };
        }
      }
    } else if (consumed.platform === "ios") {
      if (!keyId || body.kind === undefined) return errorResponse(400, "ERR_INVALID_ARGUMENT");
      if (!deps.appAttest) {
        verdict = unevaluated("ios", "app_attest_not_configured", now());
      } else {
        try {
          verdict = await evaluateAppAttest(deps.appAttest, {
            userId,
            deviceId: consumed.deviceId,
            nonce: body.nonce,
            token: body.token,
            keyIdBase64: body.key_id as string,
            keyId,
            kind: body.kind as "attestation" | "assertion",
            nowMs: now(),
          });
        } catch (err) {
          log("error", "device_integrity.app_attest_store_error", { error: String(err) });
          return errorResponse(500, "ERR_INTERNAL");
        }
      }
    } else {
      verdict = unevaluated("web", "platform_not_attestable", now());
    }

    try {
      await deps.store.saveVerdict(consumed.deviceId, userId, verdict);
    } catch (err) {
      log("error", "device_integrity.save_failed", { error: String(err) });
      return errorResponse(500, "ERR_INTERNAL");
    }

    log("info", "device_integrity.verdict", {
      device_id: consumed.deviceId,
      purpose: consumed.purpose,
      status: verdict.status,
      reasons: verdict.reasons,
    });
    return json({ status: verdict.status, reasons: verdict.reasons, purpose: consumed.purpose });
  };
}

interface AppAttestRequest {
  userId: string;
  deviceId: string;
  nonce: string;
  token: string;
  keyIdBase64: string;
  keyId: Uint8Array;
  kind: "attestation" | "assertion";
  nowMs: number;
}

/** Verification failures become a `fail` verdict; store errors throw (the caller returns 500). */
async function evaluateAppAttest(deps: AppAttestDeps, req: AppAttestRequest): Promise<IntegrityVerdict> {
  const checkedAt = new Date(req.nowMs).toISOString();
  const fail = (reason: string): IntegrityVerdict => ({
    status: "fail",
    platform: "ios",
    reasons: [reason],
    checkedAt,
    signals: { appAttestKind: req.kind },
  });
  const object = decodeBase64(req.token);
  if (!object) return fail(`${req.kind}_malformed`);
  const clientDataHash = await sha256(new TextEncoder().encode(req.nonce));

  if (req.kind === "attestation") {
    const outcome = await (deps.verifyAttestation ?? verifyAttestation)(
      object,
      req.keyId,
      clientDataHash,
      deps.policy,
      new Date(req.nowMs),
    );
    if (!outcome.ok) return fail(outcome.reason);
    // Apple: verify the receipt that comes with the attestation before storing it.
    const receipt = await (deps.verifyReceipt ?? verifyReceipt)(outcome.receipt, {
      appId: deps.policy.appId,
      publicKey: outcome.publicKey,
      now: new Date(req.nowMs),
    });
    if (!receipt.ok) return fail(receipt.reason);
    const registered = await deps.store.registerKey({
      userId: req.userId,
      deviceId: req.deviceId,
      keyId: req.keyIdBase64,
      publicKey: toBase64(outcome.publicKey),
      receipt: toBase64(outcome.receipt),
      receiptExpiresAt: receipt.receipt.expirationTime?.toISOString(),
      environment: deps.policy.environment,
      validationCategory: outcome.extensions.validationCategory,
      bundleVersion: outcome.extensions.bundleVersion,
    });
    if (!registered) return fail("app_attest_key_already_registered");
    return pass(req, deps.policy, outcome.extensions, checkedAt);
  }

  const key = await deps.store.keyForAssertion(req.userId, req.deviceId, req.keyIdBase64);
  if (!key) return fail("app_attest_key_unknown");
  if (key.environment !== deps.policy.environment) return fail("environment_mismatch");
  const publicKey = decodeBase64(key.publicKey);
  if (!publicKey) throw new Error("stored_public_key_not_base64");
  const outcome = await (deps.verifyAssertion ?? verifyAssertion)(
    object,
    clientDataHash,
    publicKey,
    key.signCount,
    deps.policy,
  );
  if (!outcome.ok) return fail(outcome.reason);
  // Compare-and-set in the database: a concurrent replay of the same assertion loses here.
  if (!await deps.store.recordAssertion(req.userId, req.keyIdBase64, outcome.counter)) {
    return fail("counter_not_increasing");
  }
  return pass(req, deps.policy, outcome.extensions, checkedAt);
}

function pass(
  req: AppAttestRequest,
  policy: AppAttestPolicy,
  extensions: { validationCategory?: number; bundleVersion?: string },
  checkedAt: string,
): IntegrityVerdict {
  return {
    status: "pass",
    platform: "ios",
    reasons: [],
    checkedAt,
    signals: {
      appAttestKind: req.kind,
      appAttestEnvironment: policy.environment,
      validationCategory: extensions.validationCategory,
      bundleVersion: extensions.bundleVersion,
    },
  };
}

function toBase64(bytes: Uint8Array): string {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary);
}

function unevaluated(platform: IntegrityVerdict["platform"], reason: string, nowMs: number): IntegrityVerdict {
  return { status: "unevaluated", platform, reasons: [reason], checkedAt: new Date(nowMs).toISOString() };
}
