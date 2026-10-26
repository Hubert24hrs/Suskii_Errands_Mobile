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

import { type ServiceAccount, ServiceAccountTokens } from "../google/access_token.ts";
import {
  type DeliveryResult,
  type NotificationMessage,
  type NotificationSender,
  pushPayload,
  type PushTarget,
} from "./sender.ts";

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

export { parseServiceAccount, type ServiceAccount } from "../google/access_token.ts";

export class FcmSender implements NotificationSender {
  readonly name = "fcm";
  readonly channel = "push" as const;
  private readonly tokens: ServiceAccountTokens;
  private readonly fetchFn: typeof fetch;

  constructor(private readonly options: FcmSenderOptions) {
    this.fetchFn = options.fetch ?? fetch;
    this.tokens = new ServiceAccountTokens(options.serviceAccount, SCOPE, { fetch: options.fetch, now: options.now });
  }

  async send(message: NotificationMessage, targets: PushTarget[], signal: AbortSignal): Promise<DeliveryResult> {
    const devices = targets.filter((t) => t.platform === "android" && t.pushToken);
    if (devices.length === 0) return { ok: false, provider: this.name, reason: "no_registered_device" };

    const data = Object.fromEntries(
      Object.entries(pushPayload(message)).map(([k, v]) => [k, String(v)]),
    );
    const accessToken = await this.tokens.get(signal);
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
