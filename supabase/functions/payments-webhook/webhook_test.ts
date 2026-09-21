import { assertEquals } from "@std/assert";
import { ConsolePaymentProvider, hmacSha256Hex } from "../_shared/payments/provider.ts";
import { createPaymentsWebhookHandler, type WebhookDeps } from "./handler.ts";

const SECRET = "test-secret";

function deps(overrides: Partial<WebhookDeps> = {}) {
  const calls: string[] = [];
  const seen = new Set<string>();
  const base: WebhookDeps = {
    providers: new Map([["console", new ConsolePaymentProvider("development", SECRET)]]),
    ingest(gateway, eventId, valid) {
      calls.push(`ingest:${gateway}:${eventId}:${valid}`);
      if (seen.has(eventId)) return Promise.resolve(null);
      seen.add(eventId);
      return Promise.resolve(1);
    },
    confirmPayment(_g, reference, amount, fee) {
      calls.push(`confirm:${reference}:${amount}:${fee}`);
      return Promise.resolve();
    },
    recordPayoutResult(_g, reference, status) {
      calls.push(`payout:${reference}:${status}`);
      return Promise.resolve();
    },
    recordChargeback(_g, reference) {
      calls.push(`chargeback:${reference}`);
      return Promise.resolve();
    },
    log() {},
    ...overrides,
  };
  return { deps: base, calls };
}

async function post(handler: (r: Request) => Promise<Response>, body: string, signature?: string) {
  return await handler(
    new Request("https://x.invalid/payments-webhook/console", {
      method: "POST",
      body,
      headers: signature === undefined ? {} : { "x-console-signature": signature },
    }),
  );
}

function charge(eventId: string, amount = 500000, fee = 14500) {
  return JSON.stringify({
    event_id: eventId,
    kind: "charge.succeeded",
    reference: "console-1",
    amount_minor: amount,
    fee_minor: fee,
  });
}

Deno.test("a verified charge is stored, verified again, then confirmed — in that order", async () => {
  const { deps: d, calls } = deps();
  const body = charge("evt-1");
  const res = await post(createPaymentsWebhookHandler(d), body, await hmacSha256Hex(SECRET, body));
  assertEquals(res.status, 200);
  assertEquals(calls, ["ingest:console:evt-1:true", "confirm:console-1:500000:14500"]);
});

Deno.test("a forged signature is stored as evidence, acknowledged, and never acted on", async () => {
  const { deps: d, calls } = deps();
  const res = await post(createPaymentsWebhookHandler(d), charge("evt-2"), "deadbeef");
  // 200, because retrying a forged event helps nobody. Stored under a hash of its own body: the
  // provider never parsed it, so there is no id of theirs to trust.
  assertEquals(res.status, 200);
  assertEquals(calls.length, 1);
  assertEquals(calls[0].startsWith("ingest:console:sha256:"), true);
  assertEquals(calls[0].endsWith(":false"), true);
});

Deno.test("the gateway's retry of an event we have seen changes nothing", async () => {
  const { deps: d, calls } = deps();
  const handler = createPaymentsWebhookHandler(d);
  const body = charge("evt-3");
  const sig = await hmacSha256Hex(SECRET, body);
  await post(handler, body, sig);
  calls.length = 0;
  const res = await post(handler, body, sig);
  assertEquals(res.status, 200);
  assertEquals(calls, ["ingest:console:evt-3:true"]);
});

Deno.test("a charge the gateway will not confirm never reaches the ledger", async () => {
  const provider = new ConsolePaymentProvider("development", SECRET);
  // The webhook says it happened; the verify call says otherwise. The verify call wins.
  provider.verifyCharge = () => Promise.resolve({ ok: true, settled: false });
  const { deps: d, calls } = deps({ providers: new Map([["console", provider]]) });
  const body = charge("evt-4");
  const res = await post(createPaymentsWebhookHandler(d), body, await hmacSha256Hex(SECRET, body));
  assertEquals(res.status, 200);
  assertEquals(calls, ["ingest:console:evt-4:true"]);
});

Deno.test("the amount the gateway confirms wins over the amount it announced", async () => {
  const provider = new ConsolePaymentProvider("development", SECRET);
  provider.verifyCharge = () => Promise.resolve({ ok: true, settled: true, amountMinor: 490000, feeMinor: 9000 });
  const { deps: d, calls } = deps({ providers: new Map([["console", provider]]) });
  const body = charge("evt-5", 500000, 14500);
  await post(createPaymentsWebhookHandler(d), body, await hmacSha256Hex(SECRET, body));
  assertEquals(calls[1], "confirm:console-1:490000:9000");
});

Deno.test("transfer outcomes route to the payout seam", async () => {
  for (
    const [kind, expected] of [
      ["transfer.succeeded", "succeeded"],
      ["transfer.failed", "failed"],
      ["transfer.reversed", "reversed"],
    ]
  ) {
    const { deps: d, calls } = deps();
    const body = JSON.stringify({ event_id: `t-${kind}`, kind, reference: "console-payout-1" });
    await post(createPaymentsWebhookHandler(d), body, await hmacSha256Hex(SECRET, body));
    assertEquals(calls[1], `payout:console-payout-1:${expected}`);
  }
});

Deno.test("an event we do not understand is recorded and left alone", async () => {
  const { deps: d, calls } = deps();
  const body = JSON.stringify({ event_id: "evt-6", kind: "vendor.invented", reference: "r" });
  const res = await post(createPaymentsWebhookHandler(d), body, await hmacSha256Hex(SECRET, body));
  assertEquals(res.status, 200);
  assertEquals(calls, ["ingest:console:evt-6:true"]);
});

Deno.test("an event with no id is stored but not processed", async () => {
  const { deps: d, calls } = deps();
  const body = JSON.stringify({ kind: "charge.succeeded", reference: "r" });
  const res = await post(createPaymentsWebhookHandler(d), body, await hmacSha256Hex(SECRET, body));
  assertEquals(res.status, 200);
  // Keyed by a hash of the body, because it still has to be recorded; not acted on, because an
  // event we cannot de-duplicate by its own id could be processed twice.
  assertEquals(calls.length, 1);
  assertEquals(calls[0].startsWith("ingest:console:sha256:"), true);
});

Deno.test("our own failure asks for a retry; a gateway's mistake does not", async () => {
  const { deps: d } = deps({
    confirmPayment: () => Promise.reject(new Error("database down")),
  });
  const body = charge("evt-7");
  const res = await post(createPaymentsWebhookHandler(d), body, await hmacSha256Hex(SECRET, body));
  assertEquals(res.status, 500);
});

Deno.test("an unknown gateway is a 404, not a guess", async () => {
  const { deps: d } = deps();
  const res = await createPaymentsWebhookHandler(d)(
    new Request("https://x.invalid/payments-webhook/flutterwave", { method: "POST", body: "{}" }),
  );
  assertEquals(res.status, 404);
});

Deno.test("only POST", async () => {
  const { deps: d } = deps();
  const res = await createPaymentsWebhookHandler(d)(
    new Request("https://x.invalid/payments-webhook/console", { method: "GET" }),
  );
  assertEquals(res.status, 405);
});
