import { assertEquals, assertRejects } from "@std/assert";
import { Webhook } from "standardwebhooks";
import { signWebhook, verifyWebhook, WebhookVerificationError } from "./standard_webhooks.ts";

// A Supabase-formatted hook secret: "v1,whsec_" + base64 of 32 bytes.
const RAW_SECRET = btoa(String.fromCharCode(...new Uint8Array(32).map((_, i) => i + 1)));
const SUPABASE_SECRET = `v1,whsec_${RAW_SECRET}`;
const BODY = JSON.stringify({ user: { phone: "2348012345678" }, sms: { otp: "123456" } });
const NOW = 1_790_000_000;

function headersFor(signature: string, id = "msg_1", ts = NOW): Headers {
  return new Headers({ "webhook-id": id, "webhook-timestamp": String(ts), "webhook-signature": signature });
}

Deno.test("matches the reference standardwebhooks library signature", async () => {
  const reference = new Webhook(RAW_SECRET).sign("msg_1", new Date(NOW * 1000), BODY);
  assertEquals(await signWebhook(SUPABASE_SECRET, "msg_1", NOW, BODY), reference);
});

Deno.test("accepts a request signed by the reference library", async () => {
  const signature = new Webhook(RAW_SECRET).sign("msg_1", new Date(NOW * 1000), BODY);
  const parsed = await verifyWebhook(BODY, headersFor(signature), SUPABASE_SECRET, NOW) as { sms: { otp: string } };
  assertEquals(parsed.sms.otp, "123456");
});

Deno.test("accepts any matching signature among several, and any of several secrets", async () => {
  const good = await signWebhook(SUPABASE_SECRET, "msg_1", NOW, BODY);
  const otherSecret = `v1,whsec_${btoa("another-secret-another-secret-12")}`;
  await verifyWebhook(BODY, headersFor(`v1,bogus ${good}`), `${otherSecret}|${SUPABASE_SECRET}`, NOW);
});

Deno.test("rejects a tampered body", async () => {
  const signature = await signWebhook(SUPABASE_SECRET, "msg_1", NOW, BODY);
  await assertRejects(
    () => verifyWebhook(BODY.replace("123456", "000000"), headersFor(signature), SUPABASE_SECRET, NOW),
    WebhookVerificationError,
    "no matching webhook signature",
  );
});

Deno.test("rejects the wrong secret", async () => {
  const signature = await signWebhook(`v1,whsec_${btoa("wrong-secret-wrong-secret-wrong!")}`, "msg_1", NOW, BODY);
  await assertRejects(() => verifyWebhook(BODY, headersFor(signature), SUPABASE_SECRET, NOW), WebhookVerificationError);
});

Deno.test("rejects replays outside the five-minute window", async () => {
  const old = NOW - 301;
  const signature = await signWebhook(SUPABASE_SECRET, "msg_1", old, BODY);
  await assertRejects(
    () => verifyWebhook(BODY, headersFor(signature, "msg_1", old), SUPABASE_SECRET, NOW),
    WebhookVerificationError,
    "timestamp outside tolerance",
  );
});

Deno.test("rejects missing headers", async () => {
  await assertRejects(
    () => verifyWebhook(BODY, new Headers(), SUPABASE_SECRET, NOW),
    WebhookVerificationError,
    "missing webhook headers",
  );
});
