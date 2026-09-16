import { assertEquals } from "@std/assert";
import { signWebhook } from "../_shared/standard_webhooks.ts";
import type { SmsProvider, SmsSendResult } from "../_shared/sms/provider.ts";
import type { CountryRoute, RouteSource } from "../_shared/sms/routing.ts";
import { createSendSmsHandler } from "./handler.ts";

const SECRET = `v1,whsec_${btoa("0123456789abcdef0123456789abcdef")}`;

class RecordingProvider implements SmsProvider {
  sent: { to: string; message: string }[] = [];
  constructor(readonly name: string, private readonly ok = true) {}
  send(to: string, message: string, _signal: AbortSignal): Promise<SmsSendResult> {
    this.sent.push({ to, message });
    return Promise.resolve(this.ok ? { ok: true, messageId: "m1" } : { ok: false, reason: "vendor_rejected" });
  }
}

const routes = (list: CountryRoute[]): RouteSource => ({ load: () => Promise.resolve(list) });
const NG: CountryRoute = { countryCode: "NG", callingCode: "234", providers: ["primary", "backup"] };

async function signedRequest(body: unknown, secret = SECRET): Promise<Request> {
  const raw = JSON.stringify(body);
  const ts = Math.floor(Date.now() / 1000);
  return new Request("http://localhost/auth-send-sms", {
    method: "POST",
    body: raw,
    headers: {
      "content-type": "application/json",
      "webhook-id": "msg_test",
      "webhook-timestamp": String(ts),
      "webhook-signature": await signWebhook(secret, "msg_test", ts, raw),
    },
  });
}

const payload = { user: { id: "u1", phone: "+2348012345678" }, sms: { otp: "654321" } };

// Silence structured logs during tests.
console.log = () => {};
console.warn = () => {};
console.error = () => {};

Deno.test("a signed request for a supported country sends the OTP and returns an empty 200", async () => {
  const primary = new RecordingProvider("primary");
  const handler = createSendSmsHandler({
    hookSecrets: SECRET,
    routes: routes([NG]),
    providers: new Map([["primary", primary]]),
  });
  const res = await handler(await signedRequest(payload));
  assertEquals(res.status, 200);
  assertEquals(await res.json(), {});
  assertEquals(primary.sent.length, 1);
  assertEquals(primary.sent[0].to, "2348012345678");
  assertEquals(primary.sent[0].message.includes("654321"), true);
});

Deno.test("fails over to the backup provider", async () => {
  const primary = new RecordingProvider("primary", false);
  const backup = new RecordingProvider("backup");
  const handler = createSendSmsHandler({
    hookSecrets: SECRET,
    routes: routes([NG]),
    providers: new Map([["primary", primary], ["backup", backup]]),
  });
  const res = await handler(await signedRequest(payload));
  assertEquals(res.status, 200);
  assertEquals([primary.sent.length, backup.sent.length], [1, 1]);
});

Deno.test("an invalid signature is rejected before anything is sent", async () => {
  const primary = new RecordingProvider("primary");
  const handler = createSendSmsHandler({
    hookSecrets: SECRET,
    routes: routes([NG]),
    providers: new Map([["primary", primary]]),
  });
  const res = await handler(await signedRequest(payload, `v1,whsec_${btoa("attacker-attacker-attacker-12345")}`));
  assertEquals(res.status, 401);
  assertEquals((await res.json()).error.message, "ERR_INVALID_SIGNATURE");
  assertEquals(primary.sent.length, 0);
});

Deno.test("numbers outside supported countries are refused without sending (R-31)", async () => {
  const primary = new RecordingProvider("primary");
  const handler = createSendSmsHandler({
    hookSecrets: SECRET,
    routes: routes([NG]),
    providers: new Map([["primary", primary]]),
  });
  const res = await handler(await signedRequest({ ...payload, user: { phone: "+14155550100" } }));
  assertEquals(res.status, 400);
  assertEquals((await res.json()).error.message, "ERR_COUNTRY_NOT_SUPPORTED");
  assertEquals(primary.sent.length, 0);
});

Deno.test("delivery failure on every provider is a non-retryable 500", async () => {
  const handler = createSendSmsHandler({
    hookSecrets: SECRET,
    routes: routes([NG]),
    providers: new Map([["primary", new RecordingProvider("primary", false)]]),
  });
  const res = await handler(await signedRequest(payload));
  // 429 and 503 would make Auth retry and send duplicate OTPs.
  assertEquals(res.status, 500);
  assertEquals(res.headers.get("content-type"), "application/json");
  assertEquals((await res.json()).error, { http_code: 500, message: "ERR_SMS_DELIVERY_FAILED" });
});

Deno.test("malformed OTPs and missing secrets are refused", async () => {
  const providers = new Map([["primary", new RecordingProvider("primary")]]);
  const bad = await createSendSmsHandler({ hookSecrets: SECRET, routes: routes([NG]), providers })(
    await signedRequest({ ...payload, sms: { otp: "12" } }),
  );
  assertEquals(bad.status, 400);
  const unconfigured = await createSendSmsHandler({ hookSecrets: undefined, routes: routes([NG]), providers })(
    await signedRequest(payload),
  );
  assertEquals(unconfigured.status, 500);
});

Deno.test("a country with no configured providers is a routing error, not a silent success", async () => {
  const handler = createSendSmsHandler({
    hookSecrets: SECRET,
    routes: routes([{ ...NG, providers: [] }]),
    providers: new Map(),
  });
  const res = await handler(await signedRequest(payload));
  assertEquals(res.status, 500);
  assertEquals((await res.json()).error.message, "ERR_SMS_ROUTING_UNAVAILABLE");
});
