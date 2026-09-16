// Play Integrity (classic requests) — server-side decode and verdict policy.
// Field names and values follow developer.android.com/google/play/integrity/verdicts and
// /classic (checked 2026-09-16).

export interface PlayIntegrityPayload {
  requestDetails?: { requestPackageName?: string; nonce?: string; timestampMillis?: string | number };
  appIntegrity?: { appRecognitionVerdict?: string; packageName?: string; versionCode?: string };
  deviceIntegrity?: { deviceRecognitionVerdict?: string[] };
  accountDetails?: { appLicensingVerdict?: string };
  environmentDetails?: { playProtectVerdict?: string; appAccessRiskVerdict?: { appsDetected?: string[] } };
}

export type IntegrityStatus = "pass" | "fail" | "unevaluated";

export interface IntegrityVerdict {
  status: IntegrityStatus;
  platform: "android" | "ios" | "web";
  reasons: string[];
  checkedAt: string;
  signals?: {
    appRecognition?: string;
    deviceRecognition?: string[];
    licensing?: string;
    playProtect?: string;
  };
}

export interface PlayPolicy {
  packageName: string;
  maxAgeMs: number;
}

/**
 * The spec makes rooted, emulated or tampered devices ineligible for money and referral
 * features. Pass requires all of: the request was for our package and this nonce, the verdict
 * is fresh, Play recognises the app binary, the device meets device integrity, and the app was
 * installed from Play. Play Protect findings are recorded as signals, not failures, until the
 * risk engine decides how to weigh them.
 */
export function evaluatePlayIntegrity(
  payload: PlayIntegrityPayload,
  expectedNonce: string,
  policy: PlayPolicy,
  nowMs: number,
): IntegrityVerdict {
  const reasons: string[] = [];
  const details = payload.requestDetails ?? {};

  if (details.requestPackageName !== policy.packageName) reasons.push("package_mismatch");
  if (details.nonce !== expectedNonce) reasons.push("nonce_mismatch");

  const ts = Number(details.timestampMillis);
  if (!Number.isFinite(ts) || nowMs - ts > policy.maxAgeMs || ts - nowMs > 60_000) {
    reasons.push("stale_verdict");
  }

  const appRecognition = payload.appIntegrity?.appRecognitionVerdict;
  if (appRecognition !== "PLAY_RECOGNIZED") reasons.push("app_not_recognized");

  const deviceRecognition = payload.deviceIntegrity?.deviceRecognitionVerdict ?? [];
  if (!deviceRecognition.includes("MEETS_DEVICE_INTEGRITY")) reasons.push("device_integrity_failed");

  const licensing = payload.accountDetails?.appLicensingVerdict;
  if (licensing !== "LICENSED") reasons.push("app_not_licensed");

  return {
    status: reasons.length === 0 ? "pass" : "fail",
    platform: "android",
    reasons,
    checkedAt: new Date(nowMs).toISOString(),
    signals: {
      appRecognition,
      deviceRecognition,
      licensing,
      playProtect: payload.environmentDetails?.playProtectVerdict,
    },
  };
}

export interface PlayIntegrityDecoder {
  decode(packageName: string, integrityToken: string): Promise<PlayIntegrityPayload>;
}

/** Decodes tokens with Google's decodeIntegrityToken endpoint. */
export class GooglePlayIntegrityDecoder implements PlayIntegrityDecoder {
  constructor(
    private readonly accessToken: () => Promise<string>,
    private readonly fetchImpl: typeof fetch = fetch,
  ) {}

  async decode(packageName: string, integrityToken: string): Promise<PlayIntegrityPayload> {
    const url = `https://playintegrity.googleapis.com/v1/${encodeURIComponent(packageName)}:decodeIntegrityToken`;
    const res = await this.fetchImpl(url, {
      method: "POST",
      headers: {
        authorization: `Bearer ${await this.accessToken()}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({ integrity_token: integrityToken }),
      signal: AbortSignal.timeout(5_000),
    });
    if (!res.ok) throw new Error(`play_integrity_decode_http_${res.status}`);
    const body = await res.json() as { tokenPayloadExternal?: PlayIntegrityPayload };
    if (!body.tokenPayloadExternal) throw new Error("play_integrity_decode_empty");
    return body.tokenPayloadExternal;
  }
}
