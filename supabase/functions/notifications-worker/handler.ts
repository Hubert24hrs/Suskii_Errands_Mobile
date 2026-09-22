import {
  type DeliveryResult,
  type NotificationMessage,
  type NotificationSender,
  pushPayload,
  type PushTarget,
} from "../_shared/notifications/sender.ts";

// The outbox's second reader. It claims the `user` aggregate and acts on one event type:
//
//   notification.created  → send on each channel `private.notify` already decided
//
// **The decision is not re-made here.** `notify` read the recipient's preferences, applied quiet
// hours, exempted the job-critical kinds (SH-16) and wrote the answer onto the event. A worker
// that recomputed any of that would be a second opinion about whether to wake somebody at 3 a.m.,
// and two opinions is one too many.
//
// **One event, several channels, one outcome each.** A push that fails does not stop the SMS: a
// person who missed a job because their token was stale should still get the text. Each channel's
// answer is recorded separately, so "did they get it" has a per-channel answer rather than a
// shrug. The event is only failed — and so retried — when *every* channel failed, because
// retrying the whole event would re-send the channels that worked.

export interface ClaimedEvent {
  id: number;
  aggregate: string;
  aggregate_id: string;
  event_type: string;
  payload: Record<string, unknown>;
  attempts: number;
}

export interface WorkerDeps {
  /** Keyed by channel: `push`, `sms`, `email`, `whatsapp`. */
  senders: ReadonlyMap<string, NotificationSender>;
  claim(aggregates: string[], limit: number): Promise<ClaimedEvent[]>;
  complete(id: number): Promise<void>;
  fail(id: number, reasonKey: string, retry: boolean): Promise<void>;
  pushTargets(userId: string): Promise<PushTarget[]>;
  recordDelivery(
    notificationId: number,
    userId: string,
    channel: string,
    provider: string,
    status: "sent" | "failed" | "skipped",
    reasonKey?: string,
  ): Promise<void>;
  log(level: "info" | "warn" | "error", event: string, fields?: Record<string, unknown>): void;
}

export interface WorkerResult {
  claimed: number;
  completed: number;
  failed: number;
  delivered: number;
}

const TIMEOUT_MS = 10_000;

export function createNotificationsWorker(deps: WorkerDeps) {
  return async function run(limit = 50): Promise<WorkerResult> {
    const events = await deps.claim(["user"], limit);
    let completed = 0, failed = 0, delivered = 0;

    for (const event of events) {
      try {
        if (event.event_type !== "notification.created") {
          // Another `user` event — a mode switch, a device registration. Not ours, and marked
          // done so it stops being claimed, but said out loud: an event nobody handles on an
          // aggregate we claim is how a refund went missing once (audit T.2).
          deps.log("warn", "notifications.worker.unhandled_event", {
            event_id: event.id,
            event_type: event.event_type,
          });
          await deps.complete(event.id);
          completed++;
          continue;
        }

        const message = toMessage(event);
        if (!message) {
          await deps.fail(event.id, "ERR_INVALID_PAYLOAD", false);
          failed++;
          continue;
        }

        const channels = readChannels(event.payload);
        if (channels.length === 0) {
          // Quiet hours, or every channel switched off. Not a failure — the decision was taken
          // upstream and the inbox row is the record either way.
          deps.log("info", "notifications.worker.no_channels", {
            notification_id: message.notificationId,
          });
          await deps.complete(event.id);
          completed++;
          continue;
        }

        const targets = channels.includes("push") ? await deps.pushTargets(message.userId) : [];
        let anySent = false;

        for (const channel of channels) {
          const sender = deps.senders.get(channel);
          if (!sender) {
            // A channel the deployment has no sender for. Recorded as skipped rather than failed:
            // nothing went wrong, something is not configured, and the two want different alerts.
            await deps.recordDelivery(
              message.notificationId,
              message.userId,
              channel,
              "none",
              "skipped",
              "no_sender_configured",
            );
            continue;
          }

          let result: DeliveryResult;
          try {
            result = await sender.send(message, targets, AbortSignal.timeout(TIMEOUT_MS));
          } catch (error) {
            result = {
              ok: false,
              provider: sender.name,
              reason: error instanceof Error ? "sender_threw" : "unknown",
            };
          }

          await deps.recordDelivery(
            message.notificationId,
            message.userId,
            channel,
            result.provider,
            result.ok ? "sent" : "failed",
            result.ok ? undefined : (result.reason ?? "unknown"),
          );
          if (result.ok) {
            anySent = true;
            delivered++;
          }
        }

        if (anySent) {
          await deps.complete(event.id);
          completed++;
        } else {
          // Every channel failed, so the whole event is worth retrying. Retrying when one channel
          // succeeded would re-send that one.
          await deps.fail(event.id, "ERR_NOTIFICATION_UNDELIVERED", true);
          failed++;
        }
      } catch (error) {
        deps.log("error", "notifications.worker.unhandled", {
          event_id: event.id,
          reason: error instanceof Error ? error.message : "unknown",
        });
        await deps.fail(event.id, "ERR_INTERNAL", true);
        failed++;
      }
    }

    return { claimed: events.length, completed, failed, delivered };
  };
}

const CHANNELS = ["push", "sms", "email", "whatsapp"];

function readChannels(payload: Record<string, unknown>): string[] {
  const raw = payload.channels;
  if (!Array.isArray(raw)) return [];
  return raw.filter((c): c is string => typeof c === "string" && CHANNELS.includes(c));
}

function toMessage(event: ClaimedEvent): NotificationMessage | null {
  const p = event.payload;
  const id = Number(p.notification_id);
  const userId = String(event.aggregate_id ?? "");
  if (!Number.isFinite(id) || id <= 0 || userId === "") return null;
  return {
    notificationId: id,
    userId,
    kind: String(p.kind ?? "system"),
    titleKey: String(p.title_key ?? ""),
    bodyKey: String(p.body_key ?? ""),
    params: (p.params && typeof p.params === "object" && !Array.isArray(p.params))
      ? p.params as Record<string, unknown>
      : {},
    deepLink: typeof p.deep_link === "string" ? p.deep_link : undefined,
    urgent: p.urgent === true,
  };
}

export { pushPayload };
