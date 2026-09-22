// Notification senders (spec `notifications`; PRD SH-16, SH-17; `docs/plan/data-flow.md` rule 1).
//
// `private.notify` has already decided *whether* to send and *on which channels*, from the
// recipient's preferences and quiet hours, and it carries that decision on the outbox event.
// Nothing here re-derives it. A sender's whole job is to take a decided message and hand it to a
// vendor.
//
// **The APNs and FCM adapters are deliberately not written.** They need the project's push
// credentials and a device lab to be worth anything (spike S-03, timeline action 6), and a push
// adapter that has never woken a real handset is not an adapter. The console sender exercises
// the whole path and refuses to run in production, so a deployment that still has it registered
// fails loudly rather than silently dropping everybody's job alerts.
//
// The SMS channel does not get a second abstraction: `_shared/sms/provider.ts` already exists for
// the OTP hook, with the same console-in-development posture and the same per-country routing.

/** What a sender is given. The channel decision is already made; this is the message. */
export interface NotificationMessage {
  notificationId: number;
  userId: string;
  kind: string;
  titleKey: string;
  bodyKey: string;
  params: Record<string, unknown>;
  deepLink?: string;
  urgent: boolean;
}

export interface DeliveryResult {
  ok: boolean;
  provider: string;
  /** Stable, non-personal failure reason for logs and metrics. */
  reason?: string;
}

export interface PushTarget {
  deviceId: string;
  platform: "android" | "ios" | "web";
  pushToken?: string | null;
  voipToken?: string | null;
}

export interface NotificationSender {
  readonly name: string;
  readonly channel: "push" | "sms" | "email" | "whatsapp";
  send(
    message: NotificationMessage,
    targets: PushTarget[],
    signal: AbortSignal,
  ): Promise<DeliveryResult>;
}

/**
 * **The push payload rule, enforced here rather than trusted to a caller.**
 *
 * Data flow rule 1 and SH-17: a push carries an identifier and a generic title, and nothing else.
 * A notification's `params` routinely hold an amount, a job id, a provider's name — exactly what
 * a lock screen shows to whoever is holding the phone, and exactly what a push vendor keeps in
 * its own logs. So the payload is *built* from the message rather than being the message: the
 * keys go, the params stay behind, and the app fetches the real content over an authenticated
 * connection when it opens.
 *
 * `request_id` survives because the app needs something to fetch, and an opaque id on a lock
 * screen tells a shoulder-surfer nothing.
 */
export function pushPayload(message: NotificationMessage): Record<string, unknown> {
  const requestId = typeof message.params.request_id === "string" ? message.params.request_id : undefined;
  return {
    notification_id: message.notificationId,
    kind: message.kind,
    // A key, not a sentence: the app translates it. A server that shipped rendered text would be
    // shipping the user's language and their content to a vendor's logs.
    title_key: message.titleKey,
    ...(requestId ? { request_id: requestId } : {}),
    ...(message.deepLink ? { deep_link: message.deepLink } : {}),
  };
}

/** Never in a payload, whatever a future caller puts in `params`. */
const FORBIDDEN_IN_PUSH = [
  "amount_minor",
  "currency",
  "display_name",
  "phone",
  "body_key",
  "params",
  "pin",
  "token",
];

/** Used by the test, and by anybody adding a sender: the rule is checkable, so check it. */
export function payloadIsSafe(payload: Record<string, unknown>): boolean {
  return !Object.keys(payload).some((k) => FORBIDDEN_IN_PUSH.includes(k));
}

/**
 * Development sender. Accepts everything, delivers nothing, and **refuses to run in production**,
 * so a deployment that has not registered a real one fails loudly instead of quietly dropping
 * every job alert on the platform.
 */
export class ConsoleNotificationSender implements NotificationSender {
  readonly name = "console";

  constructor(
    readonly channel: "push" | "sms" | "email" | "whatsapp",
    private readonly environment: string,
  ) {}

  send(
    _message: NotificationMessage,
    targets: PushTarget[],
  ): Promise<DeliveryResult> {
    if (this.environment === "production") {
      return Promise.resolve({
        ok: false,
        provider: this.name,
        reason: "console_sender_disabled_in_production",
      });
    }
    // A push with nowhere to go is not a failure of the sender; it is a person who has not opened
    // the app on a device yet, and recording it as `failed` would make the health check cry wolf.
    if (this.channel === "push" && targets.length === 0) {
      return Promise.resolve({ ok: false, provider: this.name, reason: "no_registered_device" });
    }
    return Promise.resolve({ ok: true, provider: this.name });
  }
}

export type SenderRegistry = ReadonlyMap<string, NotificationSender>;
