import { assertEquals } from "@std/assert";
import {
  ConsoleNotificationSender,
  type NotificationSender,
  payloadIsSafe,
  pushPayload,
} from "../_shared/notifications/sender.ts";
import { type ClaimedEvent, createNotificationsWorker, type WorkerDeps } from "./handler.ts";

function senders(environment = "development"): Map<string, NotificationSender> {
  return new Map(
    (["push", "sms", "email", "whatsapp"] as const).map((
      c,
    ) => [c, new ConsoleNotificationSender(c, environment)]),
  );
}

function deps(events: ClaimedEvent[], overrides: Partial<WorkerDeps> = {}) {
  const calls: string[] = [];
  const base: WorkerDeps = {
    senders: senders(),
    claim: () => Promise.resolve(events),
    complete: (id) => {
      calls.push(`complete:${id}`);
      return Promise.resolve();
    },
    fail: (id, reason, retry) => {
      calls.push(`fail:${id}:${reason}:${retry}`);
      return Promise.resolve();
    },
    pushTargets: () => Promise.resolve([{ deviceId: "d1", platform: "android" as const, pushToken: "tok" }]),
    recordDelivery: (_id, _user, channel, provider, status, reason) => {
      calls.push(`${channel}:${status}:${provider}:${reason ?? ""}`);
      return Promise.resolve();
    },
    log: () => {},
    ...overrides,
  };
  return { deps: base, calls };
}

function notification(channels: string[], extra: Record<string, unknown> = {}): ClaimedEvent {
  return {
    id: 1,
    aggregate: "user",
    aggregate_id: "11111111-1111-4111-8111-111111111111",
    event_type: "notification.created",
    payload: {
      notification_id: 42,
      kind: "job_status",
      title_key: "notification.job.assigned.title",
      body_key: "notification.job.assigned.body",
      params: { request_id: "req-1", amount_minor: 10000, currency: "NGN" },
      deep_link: "/jobs/req-1",
      channels,
      urgent: true,
      ...extra,
    },
    attempts: 1,
  };
}

Deno.test("each decided channel is sent and recorded separately", async () => {
  const { deps: d, calls } = deps([notification(["push", "sms"])]);
  const result = await createNotificationsWorker(d)();
  assertEquals(result, { claimed: 1, completed: 1, failed: 0, delivered: 2 });
  assertEquals(calls, ["push:sent:console:", "sms:sent:console:", "complete:1"]);
});

Deno.test("the worker does not second-guess the channel decision", async () => {
  // Quiet hours, or everything switched off: `notify` already decided, and an empty list is that
  // decision rather than a mistake.
  const { deps: d, calls } = deps([notification([])]);
  const result = await createNotificationsWorker(d)();
  assertEquals(result.completed, 1);
  assertEquals(calls, ["complete:1"]);
});

Deno.test("a failed push does not stop the SMS", async () => {
  const s = senders();
  s.set("push", {
    name: "broken",
    channel: "push",
    send: () => Promise.resolve({ ok: false, provider: "broken", reason: "token_expired" }),
  });
  const { deps: d, calls } = deps([notification(["push", "sms"])], { senders: s });
  const result = await createNotificationsWorker(d)();
  // Somebody who missed a job because their push token was stale should still get the text.
  assertEquals(calls, ["push:failed:broken:token_expired", "sms:sent:console:", "complete:1"]);
  assertEquals(result.delivered, 1);
});

Deno.test("an event is only retried when every channel failed", async () => {
  const s = senders();
  for (const c of ["push", "sms"] as const) {
    s.set(c, {
      name: "broken",
      channel: c,
      send: () => Promise.resolve({ ok: false, provider: "broken", reason: "vendor_down" }),
    });
  }
  const { deps: d, calls } = deps([notification(["push", "sms"])], { senders: s });
  const result = await createNotificationsWorker(d)();
  assertEquals(result.failed, 1);
  assertEquals(calls.at(-1), "fail:1:ERR_NOTIFICATION_UNDELIVERED:true");
});

Deno.test("a channel with no sender is skipped, not failed", async () => {
  const s = senders();
  s.delete("whatsapp");
  const { deps: d, calls } = deps([notification(["push", "whatsapp"])], { senders: s });
  await createNotificationsWorker(d)();
  // Nothing went wrong; something is not configured, and the two deserve different alerts.
  assertEquals(calls, ["push:sent:console:", "whatsapp:skipped:none:no_sender_configured", "complete:1"]);
});

Deno.test("a sender that throws is a failed delivery, not a dead batch", async () => {
  const s = senders();
  s.set("push", {
    name: "broken",
    channel: "push",
    send: () => Promise.reject(new Error("socket hang up")),
  });
  const { deps: d, calls } = deps([notification(["push", "sms"])], { senders: s });
  const result = await createNotificationsWorker(d)();
  assertEquals(calls[0], "push:failed:broken:sender_threw");
  assertEquals(result.completed, 1);
});

Deno.test("a push with nowhere to go is not a vendor failure", async () => {
  const { deps: d, calls } = deps([notification(["push"])], {
    pushTargets: () => Promise.resolve([]),
  });
  await createNotificationsWorker(d)();
  assertEquals(calls[0], "push:failed:console:no_registered_device");
});

Deno.test("the console sender refuses to run in production", async () => {
  const { deps: d, calls } = deps([notification(["push"])], { senders: senders("production") });
  await createNotificationsWorker(d)();
  assertEquals(calls[0], "push:failed:console:console_sender_disabled_in_production");
});

Deno.test("another user event is completed, and said out loud", async () => {
  const seen: string[] = [];
  const { deps: d } = deps([{
    id: 7,
    aggregate: "user",
    aggregate_id: "u",
    event_type: "user.mode_changed",
    payload: {},
    attempts: 1,
  }], { log: (level, event) => seen.push(`${level}:${event}`) });
  const result = await createNotificationsWorker(d)();
  assertEquals(result.completed, 1);
  assertEquals(seen, ["warn:notifications.worker.unhandled_event"]);
});

Deno.test("an event with no notification id is not retried for ever", async () => {
  const bad = notification(["push"]);
  delete bad.payload.notification_id;
  const { deps: d, calls } = deps([bad]);
  await createNotificationsWorker(d)();
  assertEquals(calls, ["fail:1:ERR_INVALID_PAYLOAD:false"]);
});

// ---------------------------------------------------------------------------
// The payload rule (data flow rule 1, SH-17).
// ---------------------------------------------------------------------------
Deno.test("a push payload carries an id and a key, and nothing a lock screen should not show", () => {
  const payload = pushPayload({
    notificationId: 42,
    userId: "u",
    kind: "job_status",
    titleKey: "notification.job.assigned.title",
    bodyKey: "notification.job.assigned.body",
    params: { request_id: "req-1", amount_minor: 10000, currency: "NGN", display_name: "Adaeze" },
    deepLink: "/jobs/req-1",
    urgent: true,
  });
  assertEquals(payloadIsSafe(payload), true);
  assertEquals(payload, {
    notification_id: 42,
    kind: "job_status",
    title_key: "notification.job.assigned.title",
    request_id: "req-1",
    deep_link: "/jobs/req-1",
  });
  // The amount and the name were in `params` and did not survive: a push is read by whoever is
  // holding the phone, and kept by whichever vendor carried it.
  assertEquals("amount_minor" in payload, false);
  assertEquals("display_name" in payload, false);
  assertEquals("body_key" in payload, false);
});

Deno.test("a notification with no request keeps a payload that is still safe", () => {
  const payload = pushPayload({
    notificationId: 9,
    userId: "u",
    kind: "system",
    titleKey: "notification.account.suspended.title",
    bodyKey: "notification.account.suspended.body",
    params: { reason_key: "under_investigation" },
    urgent: false,
  });
  assertEquals(payloadIsSafe(payload), true);
  assertEquals(payload, {
    notification_id: 9,
    kind: "system",
    title_key: "notification.account.suspended.title",
  });
});
