import { assert, assertEquals } from "@std/assert";
import { decodeJwt } from "jose";
import { FcmSender, parseServiceAccount, type ServiceAccount } from "./fcm.ts";
import { type NotificationMessage, payloadIsSafe } from "./sender.ts";

async function serviceAccount(): Promise<ServiceAccount> {
  const pair = await crypto.subtle.generateKey(
    { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
    true,
    ["sign", "verify"],
  );
  const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  const b64 = btoa(String.fromCharCode(...der)).replace(/(.{64})/g, "$1\n");
  return {
    project_id: "suskii-test",
    client_email: "fcm-sender@suskii-test.iam.gserviceaccount.com",
    private_key: `-----BEGIN PRIVATE KEY-----\n${b64}\n-----END PRIVATE KEY-----\n`,
    token_uri: "https://oauth2.example.test/token",
  };
}

const message: NotificationMessage = {
  notificationId: 42,
  userId: "11111111-1111-4111-8111-111111111111",
  kind: "job_status",
  titleKey: "notification.job.assigned.title",
  bodyKey: "notification.job.assigned.body",
  params: { request_id: "req-1", amount_minor: 10000, display_name: "Adaeze" },
  deepLink: "/jobs/req-1",
  urgent: true,
};

interface Recorded {
  url: string;
  headers: Headers;
  body: string;
}

function fakeFetch(sendResponses: Array<() => Response>) {
  const requests: Recorded[] = [];
  let sends = 0;
  const fn = (input: string | URL | Request, init?: RequestInit) => {
    const url = String(input);
    requests.push({ url, headers: new Headers(init?.headers), body: String(init?.body ?? "") });
    if (url.endsWith("/token")) {
      return Promise.resolve(Response.json({ access_token: "ya29.test", expires_in: 3600 }));
    }
    const next = sendResponses[Math.min(sends++, sendResponses.length - 1)];
    return Promise.resolve(next());
  };
  return { fn: fn as typeof fetch, requests };
}

const ok = () => Response.json({ name: "projects/suskii-test/messages/1" });
const signal = () => AbortSignal.timeout(5_000);

Deno.test("a push is sent per Android token, with the safe payload and a generic text", async () => {
  const { fn, requests } = fakeFetch([ok]);
  const dead: string[] = [];
  const sender = new FcmSender({
    serviceAccount: await serviceAccount(),
    onDeadToken: (id) => Promise.resolve(void dead.push(id)),
    fetch: fn,
  });
  const result = await sender.send(message, [
    { deviceId: "d1", platform: "android", pushToken: "tok-1" },
    { deviceId: "d2", platform: "android", pushToken: "tok-2" },
    { deviceId: "d3", platform: "ios", pushToken: "apns-tok" },
    { deviceId: "d4", platform: "android", pushToken: null },
  ], signal());

  assertEquals(result, { ok: true, provider: "fcm" });
  const sends = requests.filter((r) => r.url.includes("/messages:send"));
  assertEquals(sends.length, 2);
  assertEquals(sends[0].url, "https://fcm.googleapis.com/v1/projects/suskii-test/messages:send");
  assertEquals(sends[0].headers.get("authorization"), "Bearer ya29.test");

  const body = JSON.parse(sends[0].body).message;
  assertEquals(body.token, "tok-1");
  assertEquals(body.notification, { title: "Suskii Errands", body: "You have a new update. Open the app to see it." });
  assertEquals(body.android, { priority: "high", ttl: "3600s" });
  // FCM refuses non-string data values, and nothing personal may ride along.
  assert(Object.values(body.data).every((v) => typeof v === "string"));
  assert(payloadIsSafe(body.data));
  assertEquals(body.data.request_id, "req-1");
  assertEquals(body.data.notification_id, "42");
  assert(!JSON.stringify(body).includes("Adaeze"));
  assert(!JSON.stringify(body).includes("10000"));
  assertEquals(dead, []);
});

Deno.test("the access token is minted once and reused", async () => {
  const { fn, requests } = fakeFetch([ok]);
  const sa = await serviceAccount();
  const sender = new FcmSender({ serviceAccount: sa, onDeadToken: () => Promise.resolve(), fetch: fn });
  const target = [{ deviceId: "d1", platform: "android" as const, pushToken: "tok-1" }];
  await sender.send(message, target, signal());
  await sender.send(message, target, signal());

  const tokenCalls = requests.filter((r) => r.url === sa.token_uri);
  assertEquals(tokenCalls.length, 1);
  const form = new URLSearchParams(tokenCalls[0].body);
  assertEquals(form.get("grant_type"), "urn:ietf:params:oauth:grant-type:jwt-bearer");
  const claims = decodeJwt(form.get("assertion")!);
  assertEquals(claims.iss, sa.client_email);
  assertEquals(claims.aud, sa.token_uri);
  assertEquals(claims.scope, "https://www.googleapis.com/auth/firebase.messaging");
});

Deno.test("an unregistered token is reported dead and the push fails", async () => {
  const { fn } = fakeFetch([() =>
    Response.json({
      error: {
        code: 404,
        status: "NOT_FOUND",
        details: [{ "@type": "type.googleapis.com/google.firebase.fcm.v1.FcmError", errorCode: "UNREGISTERED" }],
      },
    }, { status: 404 })]);
  const dead: string[] = [];
  const sender = new FcmSender({
    serviceAccount: await serviceAccount(),
    onDeadToken: (id) => Promise.resolve(void dead.push(id)),
    fetch: fn,
  });
  const result = await sender.send(message, [{ deviceId: "d1", platform: "android", pushToken: "old" }], signal());
  assertEquals(result, { ok: false, provider: "fcm", reason: "fcm_dead_token" });
  assertEquals(dead, ["d1"]);
});

Deno.test("a bad request is our payload's fault, so the token is kept", async () => {
  const { fn } = fakeFetch([() =>
    Response.json({
      error: {
        code: 400,
        status: "INVALID_ARGUMENT",
        details: [
          { "@type": "type.googleapis.com/google.rpc.BadRequest" },
          { "@type": "type.googleapis.com/google.firebase.fcm.v1.FcmError", errorCode: "INVALID_ARGUMENT" },
        ],
      },
    }, { status: 400 })]);
  const dead: string[] = [];
  const sender = new FcmSender({
    serviceAccount: await serviceAccount(),
    onDeadToken: (id) => Promise.resolve(void dead.push(id)),
    fetch: fn,
  });
  const result = await sender.send(message, [{ deviceId: "d1", platform: "android", pushToken: "tok" }], signal());
  assertEquals(result.ok, false);
  assertEquals(result.reason, "fcm_invalid_argument");
  assertEquals(dead, []);
});

Deno.test("an invalid token reported by FCM itself is dropped", async () => {
  const { fn } = fakeFetch([() =>
    Response.json({
      error: {
        code: 400,
        status: "INVALID_ARGUMENT",
        details: [{ "@type": "type.googleapis.com/google.firebase.fcm.v1.FcmError", errorCode: "INVALID_ARGUMENT" }],
      },
    }, { status: 400 })]);
  const dead: string[] = [];
  const sender = new FcmSender({
    serviceAccount: await serviceAccount(),
    onDeadToken: (id) => Promise.resolve(void dead.push(id)),
    fetch: fn,
  });
  await sender.send(message, [{ deviceId: "d9", platform: "android", pushToken: "garbage" }], signal());
  assertEquals(dead, ["d9"]);
});

Deno.test("a vendor outage keeps the token and reports the status", async () => {
  const { fn } = fakeFetch([() => Response.json({ error: { code: 503, status: "UNAVAILABLE" } }, { status: 503 })]);
  const dead: string[] = [];
  const sender = new FcmSender({
    serviceAccount: await serviceAccount(),
    onDeadToken: (id) => Promise.resolve(void dead.push(id)),
    fetch: fn,
  });
  const result = await sender.send(message, [{ deviceId: "d1", platform: "android", pushToken: "tok" }], signal());
  assertEquals(result, { ok: false, provider: "fcm", reason: "fcm_unavailable" });
  assertEquals(dead, []);
});

Deno.test("no Android token means no registered device, without calling Google", async () => {
  const { fn, requests } = fakeFetch([ok]);
  const sender = new FcmSender({
    serviceAccount: await serviceAccount(),
    onDeadToken: () => Promise.resolve(),
    fetch: fn,
  });
  const result = await sender.send(message, [{ deviceId: "d1", platform: "ios", pushToken: "apns" }], signal());
  assertEquals(result, { ok: false, provider: "fcm", reason: "no_registered_device" });
  assertEquals(requests.length, 0);
});

Deno.test("a service account missing a field is refused before anything is sent", () => {
  let threw = false;
  try {
    parseServiceAccount(JSON.stringify({ project_id: "p", client_email: "e", token_uri: "t" }));
  } catch {
    threw = true;
  }
  assert(threw);
});
