import "@supabase/functions-js/edge-runtime.d.ts";
import { withSupabase } from "@supabase/server";
import { createAdminClient } from "@supabase/server/core";
import { log } from "../_shared/log.ts";
import { instrument } from "../_shared/observability.ts";
import { sentryReporterFromEnv } from "../_shared/sentry.ts";
import {
  ConsoleNotificationSender,
  type NotificationSender,
  type PushTarget,
} from "../_shared/notifications/sender.ts";
import { FcmSender, parseServiceAccount } from "../_shared/notifications/fcm.ts";
import { type ClaimedEvent, createNotificationsWorker } from "./handler.ts";

// Invoked every minute by pg_cron through `private.invoke_edge_worker`. Drains `private.outbox` for
// the `user` aggregate and sends what `private.notify` already decided to send.
//
// Push goes through FCM when `FCM_SERVICE_ACCOUNT_JSON` is set (Android; iOS waits on APNs and an
// Apple account). Every other channel is still the console sender, which refuses to run in
// production, so a deployment that never registered a real one fails loudly instead of quietly
// dropping every job alert on the platform.
const environment = Deno.env.get("SUSKII_ENV") ?? "development";
const admin = createAdminClient();

const senders = new Map<string, NotificationSender>(
  (["push", "sms", "email", "whatsapp"] as const).map((
    channel,
  ) => [channel, new ConsoleNotificationSender(channel, environment)]),
);
const fcmServiceAccount = Deno.env.get("FCM_SERVICE_ACCOUNT_JSON");
if (fcmServiceAccount) {
  senders.set(
    "push",
    new FcmSender({
      serviceAccount: parseServiceAccount(fcmServiceAccount),
      async onDeadToken(deviceId) {
        const { error } = await admin.rpc("dispatch_clear_push_token", { p_device_id: deviceId });
        if (error) throw new Error(error.message);
      },
    }),
  );
}

const run = createNotificationsWorker({
  senders,
  async claim(aggregates, limit) {
    const { data, error } = await admin.rpc("gateway_claim_outbox", {
      p_aggregates: aggregates,
      p_limit: limit,
    });
    if (error) throw new Error(error.message);
    return (data ?? []) as ClaimedEvent[];
  },
  async complete(id) {
    const { error } = await admin.rpc("gateway_complete_outbox", { p_id: id });
    if (error) throw new Error(error.message);
  },
  async fail(id, reasonKey, retry) {
    const { error } = await admin.rpc("gateway_fail_outbox", {
      p_id: id,
      p_reason_key: reasonKey,
      p_retry: retry,
    });
    if (error) throw new Error(error.message);
  },
  async pushTargets(userId) {
    const { data, error } = await admin.rpc("dispatch_push_targets", { p_user_id: userId });
    if (error) throw new Error(error.message);
    return ((data ?? []) as Array<
      { device_id: string; platform: string; push_token: string | null; voip_token: string | null }
    >).map((r): PushTarget => ({
      deviceId: r.device_id,
      platform: r.platform as PushTarget["platform"],
      pushToken: r.push_token,
      voipToken: r.voip_token,
    }));
  },
  async recordDelivery(notificationId, userId, channel, provider, status, reasonKey) {
    const { error } = await admin.rpc("dispatch_record_notification", {
      p_notification_id: notificationId,
      p_user_id: userId,
      p_channel: channel,
      p_provider: provider,
      p_status: status,
      p_reason_key: reasonKey ?? null,
    });
    if (error) throw new Error(error.message);
  },
  log,
});

export default {
  fetch: instrument(
    "notifications-worker",
    withSupabase({ auth: "secret:worker", cors: "disabled" }, async () => {
      const result = await run();
      return new Response(JSON.stringify(result), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    }),
    { reporter: sentryReporterFromEnv() },
  ),
};
