// Firebase Cloud Messaging sender (HTTP v1), Android only for now.
//
// Read 2026-10-26 from firebase.google.com/docs/cloud-messaging (send/v1-api, error-codes,
// manage-tokens, customize-messages/setting-message-priority and -lifespan):
//   POST https://fcm.googleapis.com/v1/projects/{project_id}/messages:send
//   Authorization: Bearer <OAuth2 access token, scope firebase.messaging, from a service account>
//   `data` values must be strings; `android.priority` is "high" or "normal"; `android.ttl` is "<n>s".
//   UNREGISTERED (404) means the token is dead. INVALID_ARGUMENT (400) means a dead token only when
//   the details carry an FcmError rather than a BadRequest, which is a bug in our payload instead.
//
// The payload is `pushPayload(message)` and nothing else (data-flow rule 1, SH-17): an id, a kind,
// a title key and a request id. The visible text is the brand and a generic line, so a lock screen
// shows that something happened and not what.

import { importPKCS8, SignJWT } from "jose";
import {
  type DeliveryResult,
  type NotificationMessage,
  type NotificationSender,
  pushPayload,
  type PushTarget,
} from "./sender.ts";

export interface ServiceAccount {
  project_id: string;
  client_email: string;
  private_key: string;
  token_uri: string;
}

export interface FcmSenderOptions {
  serviceAccount: ServiceAccount;
  /** Called once per token FCM says is dead, so it is not tried again. */
  onDeadToken(deviceId: string): Promise<void>;
  fetch?: typeof fetch;
  now?: () => number;
}

const SCOPE = "https://www.googleapis.com/auth/firebase.messaging";
const TITLE = "Suskii Errands";
const BODY = "You have a new update. Open the app to see it.";
// A push that arrives an hour late is noise; the in-app inbox still has it.
const TTL = "3600s";

export function parseServiceAccount(json: string): ServiceAccount {
  const raw = JSON.parse(json) as Partial<ServiceAccount>;
  for (const k of ["project_id", "client_email", "private_key", "token_uri"] as const) {
    if (typeof raw[k] !== "string" || raw[k] === "") throw new Error(`service account: missing ${k}`);
  }
  return raw as ServiceAccount;
}

export class FcmSender implements NotificationSender {
  readonly name = "fcm";
  readonly channel = "push" as const;
  private token?: { value: string; expiresAt: number };
  private readonly fetchFn: typeof fetch;
  private readonly now: () => number;

  constructor(private readonly options: FcmSenderOptions) {
    this.fetchFn = options.fetch ?? fetch;
    this.now = options.now ?? Date.now;
  }

  async send(message: NotificationMessage, targets: PushTarget[], signal: AbortSignal): Promise<DeliveryResult> {
    const devices = targets.filter((t) => t.platform === "android" && t.pushToken);
    if (devices.length === 0) return { ok: false, provider: this.name, reason: "no_registered_device" };

    const data = Object.fromEntries(
      Object.entries(pushPayload(message)).map(([k, v]) => [k, String(v)]),
    );
    const accessToken = await this.accessToken(signal);
    const url = `https://fcm.googleapis.com/v1/projects/${this.options.serviceAccount.project_id}/messages:send`;

    let sent = 0;
    let lastReason = "fcm_failed";
    for (const device of devices) {
      const response = await this.fetchFn(url, {
        method: "POST",
        headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
        body: JSON.stringify({
          message: {
            token: device.pushToken,
            notification: { title: TITLE, body: BODY },
            data,
            android: { priority: message.urgent ? "high" : "normal", ttl: TTL },
          },
        }),
        signal,
      });
      if (response.ok) {
        sent++;
        continue;
      }
      const error = await readError(response);
      lastReason = `fcm_${error.status.toLowerCase() || response.status}`;
      if (isDeadToken(response.status, error)) {
        await this.options.onDeadToken(device.deviceId);
        lastReason = "fcm_dead_token";
      }
    }
    return sent > 0 ? { ok: true, provider: this.name } : { ok: false, provider: this.name, reason: lastReason };
  }

  private async accessToken(signal: AbortSignal): Promise<string> {
    const nowS = Math.floor(this.now() / 1000);
    if (this.token && this.token.expiresAt - 60 > nowS) return this.token.value;

    const sa = this.options.serviceAccount;
    const key = await importPKCS8(sa.private_key, "RS256");
    const assertion = await new SignJWT({ scope: SCOPE })
      .setProtectedHeader({ alg: "RS256", typ: "JWT" })
      .setIssuer(sa.client_email)
      .setAudience(sa.token_uri)
      .setIssuedAt(nowS)
      .setExpirationTime(nowS + 3600)
      .sign(key);

    const response = await this.fetchFn(sa.token_uri, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion }),
      signal,
    });
    if (!response.ok) throw new Error(`fcm token exchange failed: ${response.status}`);
    const body = await response.json() as { access_token?: string; expires_in?: number };
    if (!body.access_token) throw new Error("fcm token exchange returned no access token");
    this.token = { value: body.access_token, expiresAt: nowS + (body.expires_in ?? 3600) };
    return body.access_token;
  }
}

interface FcmErrorBody {
  status: string;
  detailTypes: string[];
  errorCode?: string;
}

async function readError(response: Response): Promise<FcmErrorBody> {
  try {
    const body = await response.json() as {
      error?: { status?: string; details?: Array<{ "@type"?: string; errorCode?: string }> };
    };
    const details = body.error?.details ?? [];
    return {
      status: body.error?.status ?? "",
      detailTypes: details.map((d) => d["@type"] ?? ""),
      errorCode: details.find((d) => d.errorCode)?.errorCode,
    };
  } catch {
    return { status: "", detailTypes: [] };
  }
}

function isDeadToken(httpStatus: number, error: FcmErrorBody): boolean {
  if (httpStatus === 404 || error.errorCode === "UNREGISTERED" || error.status === "NOT_FOUND") return true;
  // INVALID_ARGUMENT is a dead token only when FCM says so; a BadRequest is our payload's fault.
  return httpStatus === 400 && error.errorCode === "INVALID_ARGUMENT" &&
    error.detailTypes.some((t) => t.endsWith("google.firebase.fcm.v1.FcmError")) &&
    !error.detailTypes.some((t) => t.endsWith("google.rpc.BadRequest"));
}
