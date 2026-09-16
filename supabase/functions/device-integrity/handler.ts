// Device integrity verification (PRD SH-38; threat model §1; spec phase 2).
// Flow: app calls request_integrity_nonce(device, purpose) → obtains a Play Integrity token
// (or, later, an App Attest assertion) for that nonce → POSTs { nonce, token } here with the
// user's JWT → the nonce is consumed for this user → the token is verified → the verdict is
// stored on the device row, where money, referral and go-online checks read it.

import { errorResponse, json } from "../_shared/http.ts";
import { log } from "../_shared/log.ts";
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

export interface DeviceIntegrityDeps {
  store: IntegrityStore;
  /** Undefined when Play Integrity credentials are not configured for this environment. */
  playDecoder?: PlayIntegrityDecoder;
  androidPackageName?: string;
  maxVerdictAgeMs?: number;
  now?: () => number;
}

interface RequestBody {
  nonce?: unknown;
  token?: unknown;
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
      // App Attest verification (attestation object, certificate chain, counters) is not built
      // yet; recorded explicitly so no caller mistakes it for a pass.
      verdict = unevaluated("ios", "app_attest_not_implemented", now());
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

function unevaluated(platform: IntegrityVerdict["platform"], reason: string, nowMs: number): IntegrityVerdict {
  return { status: "unevaluated", platform, reasons: [reason], checkedAt: new Date(nowMs).toISOString() };
}
