import { assert, assertEquals } from "@std/assert";
import { decodeProtectedHeader, jwtVerify } from "jose";
import { createCallTokenHandler, RpcError } from "./handler.ts";
import { credentialsFromEnv, roomToken, TOKEN_TTL_S } from "./token.ts";

const JOB = "0f0f0f0f-0000-4000-8000-000000000001";
const KEY = "key-call-000000000001";
const CREDS = {
  url: "wss://suskii-test.livekit.cloud",
  apiKey: "APItestkey",
  apiSecret: "a-test-secret-of-sufficient-length",
};

function harness(started: Record<string, unknown>, credentials: typeof CREDS | null = CREDS) {
  const calls: Array<{ fn: string; args: Record<string, unknown> }> = [];
  const handler = createCallTokenHandler({
    credentials,
    log: () => {},
    sign: (c, room, identity) => roomToken(c, room, identity, Date.UTC(2026, 9, 26, 6, 0, 0)),
    rpc(fn, args) {
      calls.push({ fn, args });
      if (fn === "start_call") return Promise.resolve([started]);
      if (fn === "answer_call") return Promise.resolve("active");
      return Promise.reject(new Error(fn));
    },
  });
  const post = (body: unknown) =>
    handler(new Request("http://x/call-token", { method: "POST", body: JSON.stringify(body) }));
  return { post, calls };
}

const ringing = (isCaller: boolean) => ({
  call_id: "c1",
  room_name: "job-0f0f-room",
  identity: "u-me",
  counterparty_id: "u-them",
  status: "ringing",
  is_caller: isCaller,
});

Deno.test("the token is LiveKit's: HS256 over the secret, the API key as issuer, one room, microphone only", async () => {
  const { token, expiresAt } = await roomToken(CREDS, "job-room", "user-1", Date.UTC(2026, 9, 26, 6, 0, 0));
  assertEquals(decodeProtectedHeader(token).alg, "HS256");
  const { payload } = await jwtVerify(token, new TextEncoder().encode(CREDS.apiSecret), {
    currentDate: new Date(Date.UTC(2026, 9, 26, 6, 1, 0)),
  });
  assertEquals(payload.iss, "APItestkey");
  assertEquals(payload.sub, "user-1");
  assertEquals(payload.exp! - payload.nbf!, TOKEN_TTL_S);
  assertEquals(payload.video, {
    room: "job-room",
    roomJoin: true,
    canPublish: true,
    canSubscribe: true,
    canPublishData: false,
    canPublishSources: ["microphone"],
  });
  assertEquals(expiresAt.toISOString(), "2026-10-26T06:10:00.000Z");
  assert(!("name" in payload), "no personal data in the token");
});

Deno.test("the caller gets a token for the room the database chose, without answering", async () => {
  const h = harness(ringing(true));
  const res = await h.post({ request_id: JOB, idempotency_key: KEY });
  assertEquals(res.status, 200);
  assertEquals(res.headers.get("cache-control"), "no-store");
  const body = await res.json();
  assertEquals([body.url, body.room_name, body.is_caller, body.status], [CREDS.url, "job-0f0f-room", true, "ringing"]);
  assertEquals(h.calls.map((c) => c.fn), ["start_call"]);
});

Deno.test("the person being rung answers through the same call, with a key of its own", async () => {
  const h = harness(ringing(false));
  const body = await (await h.post({ request_id: JOB, idempotency_key: KEY })).json();
  assertEquals(body.status, "active");
  assertEquals(h.calls.map((c) => c.fn), ["start_call", "answer_call"]);
  assertEquals(h.calls[1].args, { p_idempotency_key: `${KEY}:answer`, p_call_id: "c1" });
});

Deno.test("without LiveKit configured nobody is rung", async () => {
  const h = harness(ringing(true), null);
  const res = await h.post({ request_id: JOB, idempotency_key: KEY });
  assertEquals(res.status, 503);
  assertEquals((await res.json()).error.code, "ERR_FEATURE_UNAVAILABLE");
  assertEquals(h.calls.length, 0);
});

Deno.test("the database's refusals keep their codes", async () => {
  const handler = createCallTokenHandler({
    credentials: CREDS,
    log: () => {},
    sign: roomToken,
    rpc: () => Promise.reject(new RpcError("ERR_CALL_WINDOW_CLOSED")),
  });
  const res = await handler(
    new Request("http://x", { method: "POST", body: JSON.stringify({ request_id: JOB, idempotency_key: KEY }) }),
  );
  assertEquals(res.status, 409);
  assertEquals((await res.json()).error.code, "ERR_CALL_WINDOW_CLOSED");
});

Deno.test("bad input is refused before anything runs", async () => {
  const h = harness(ringing(true));
  assertEquals((await h.post({ request_id: "nope", idempotency_key: KEY })).status, 400);
  assertEquals((await h.post({ request_id: JOB, idempotency_key: "short" })).status, 400);
  assertEquals(h.calls.length, 0);
});

Deno.test("credentials are read strictly", () => {
  const env = (m: Record<string, string>) => (k: string) => m[k];
  assertEquals(credentialsFromEnv(env({})), null);
  assertEquals(
    credentialsFromEnv(
      env({ LIVEKIT_URL: "https://x.livekit.cloud", LIVEKIT_API_KEY: "k", LIVEKIT_API_SECRET: "s".repeat(32) }),
    ),
    null,
  );
  assertEquals(
    credentialsFromEnv(
      env({ LIVEKIT_URL: "wss://x.livekit.cloud", LIVEKIT_API_KEY: "k", LIVEKIT_API_SECRET: "s".repeat(32) }),
    )?.url,
    "wss://x.livekit.cloud",
  );
});
