import { assertEquals } from "@std/assert";
import { ConsolePaymentProvider } from "../_shared/payments/provider.ts";
import { type ClaimedEvent, createPaymentsWorker, type PayoutTarget, type WorkerDeps } from "./handler.ts";

const ROUTES = [{
  countryCode: "NG",
  providers: ["console"],
  byMethod: {},
  bands: [],
  payoutProviders: ["console"],
}];

const TARGET: PayoutTarget = {
  rail: "bank",
  institutionCode: "058",
  accountNumber: "0123456789",
  holderName: "A PROVIDER",
  countryCode: "NG",
};

function deps(events: ClaimedEvent[], overrides: Partial<WorkerDeps> = {}) {
  const calls: string[] = [];
  const base: WorkerDeps = {
    providers: new Map([["console", new ConsolePaymentProvider("development")]]),
    routes: () => Promise.resolve(ROUTES),
    claim: () => Promise.resolve(events),
    complete: (id) => {
      calls.push(`complete:${id}`);
      return Promise.resolve();
    },
    fail: (id, reason, retry) => {
      calls.push(`fail:${id}:${reason}:${retry}`);
      return Promise.resolve();
    },
    recordCheckout: (paymentId, gateway, ref) => {
      calls.push(`checkout:${paymentId}:${gateway}:${ref}`);
      return Promise.resolve();
    },
    recordPayoutResult: (payoutId, status) => {
      calls.push(`payout:${payoutId}:${status}`);
      return Promise.resolve();
    },
    recordAccountVerification: (id, verified, holder) => {
      calls.push(`verify:${id}:${verified}:${holder ?? ""}`);
      return Promise.resolve();
    },
    resolvePayoutTarget: () => Promise.resolve(TARGET),
    resolveRefund: () => Promise.resolve({ gatewayReference: "FLW-1", countryCode: "NG", gateway: "console" }),
    recordRefundResult: (id, ok, ref, reason) => {
      calls.push(`refund:${id}:${ok}:${ref}:${reason ?? ""}`);
      return Promise.resolve();
    },
    log: () => {},
    ...overrides,
  };
  return { deps: base, calls };
}

const paymentEvent: ClaimedEvent = {
  id: 1,
  aggregate: "payment",
  aggregate_id: "pay-1",
  event_type: "payment.requested",
  payload: {
    payment_id: "pay-1",
    amount_minor: 500000,
    currency: "NGN",
    country_code: "NG",
    payer_id: "cust-1",
  },
  attempts: 1,
};

Deno.test("a payment request becomes a checkout, written back", async () => {
  const { deps: d, calls } = deps([paymentEvent]);
  const result = await createPaymentsWorker(d)();
  assertEquals(result, { claimed: 1, completed: 1, failed: 0 });
  assertEquals(calls, ["checkout:pay-1:console:console-pay-1", "complete:1"]);
});

Deno.test("a payout request becomes a transfer that is pending, never successful", async () => {
  const { deps: d, calls } = deps([{
    id: 2,
    aggregate: "payout",
    aggregate_id: "po-1",
    event_type: "payout.requested",
    payload: { payout_id: "po-1", amount_minor: 8460, currency: "NGN" },
    attempts: 1,
  }]);
  await createPaymentsWorker(d)();
  // Asking for a transfer is not the same as one arriving; success comes by webhook.
  assertEquals(calls, ["payout:po-1:pending", "complete:2"]);
});

Deno.test("a name enquiry records its answer, including a negative one", async () => {
  const { deps: d, calls } = deps([{
    id: 3,
    aggregate: "payout",
    aggregate_id: "acct-1",
    event_type: "payout_account.registered",
    payload: { payout_account_id: "acct-1" },
    attempts: 1,
  }], {
    resolvePayoutTarget: () => Promise.resolve({ ...TARGET, accountNumber: "0123456780" }),
  });
  await createPaymentsWorker(d)();
  // The console provider refuses an account ending in 0, and the refusal is recorded rather than
  // leaving somebody waiting for an answer that already came.
  assertEquals(calls, ["verify:acct-1:false:", "complete:3"]);
});

Deno.test("without a decryption key there is no account number, so nothing is transferred", async () => {
  const { deps: d, calls } = deps([{
    id: 4,
    aggregate: "payout",
    aggregate_id: "po-2",
    event_type: "payout.requested",
    payload: { payout_id: "po-2", amount_minor: 100, currency: "NGN" },
    attempts: 1,
  }], { resolvePayoutTarget: undefined });
  const result = await createPaymentsWorker(d)();
  // Retryable: the key is a deployment concern and the event should still be here when it lands.
  assertEquals(calls, ["fail:4:ERR_PAYOUT_KEY_UNAVAILABLE:true"]);
  assertEquals(result.failed, 1);
});

Deno.test("a country nobody routes for fails permanently, not for ever", async () => {
  const { deps: d, calls } = deps([{
    ...paymentEvent,
    id: 5,
    payload: { ...paymentEvent.payload, country_code: "ZZ" },
  }]);
  await createPaymentsWorker(d)();
  assertEquals(calls, ["fail:5:ERR_COUNTRY_NOT_SUPPORTED:false"]);
});

Deno.test("a provider named by a country pack but not implemented looks like a mistake", async () => {
  const { deps: d, calls } = deps([paymentEvent], {
    routes: () => Promise.resolve([{ ...ROUTES[0], providers: ["flutterwave"], payoutProviders: [] }]),
  });
  await createPaymentsWorker(d)();
  assertEquals(calls, ["fail:1:ERR_NO_PROVIDER_CONFIGURED:false"]);
});

Deno.test("a gateway that refuses is retried", async () => {
  const provider = new ConsolePaymentProvider("development");
  provider.createCheckout = () => Promise.resolve({ ok: false, reason: "gateway_unavailable" });
  const { deps: d, calls } = deps([paymentEvent], {
    providers: new Map([["console", provider]]),
  });
  await createPaymentsWorker(d)();
  assertEquals(calls, ["fail:1:gateway_unavailable:true"]);
});

Deno.test("an event for somebody else's worker is completed, not retried for ever", async () => {
  const { deps: d, calls } = deps([{
    id: 6,
    aggregate: "payment",
    aggregate_id: "x",
    event_type: "payment.held",
    payload: {},
    attempts: 1,
  }]);
  await createPaymentsWorker(d)();
  assertEquals(calls, ["complete:6"]);
});

Deno.test("one event blowing up does not take the batch with it", async () => {
  const { deps: d, calls } = deps([
    { ...paymentEvent, id: 7 },
    { ...paymentEvent, id: 8 },
  ], {
    recordCheckout: (paymentId) => {
      if (paymentId === "pay-1" && calls.length === 0) {
        return Promise.reject(new Error("database down"));
      }
      calls.push("checkout:ok");
      return Promise.resolve();
    },
  });
  const result = await createPaymentsWorker(d)();
  assertEquals(result.claimed, 2);
  assertEquals(result.failed, 1);
  assertEquals(result.completed, 1);
});

const refundEvent: ClaimedEvent = {
  id: 20,
  aggregate: "payment",
  aggregate_id: "ref-1",
  event_type: "refund.requested",
  payload: {
    refund_id: "ref-1",
    payment_id: "pay-1",
    amount_minor: 4000,
    currency: "NGN",
    reason_code: "dispute_partial",
  },
  attempts: 1,
};

Deno.test("a refund is asked for, and the answer is written back", async () => {
  const { deps: d, calls } = deps([refundEvent]);
  const result = await createPaymentsWorker(d)();
  assertEquals(result, { claimed: 1, completed: 1, failed: 0 });
  assertEquals(calls, ["refund:ref-1:true:console-refund-ref-1:", "complete:20"]);
});

Deno.test("a refund the gateway refuses is recorded as failed, not left pending", async () => {
  const provider = new ConsolePaymentProvider("development");
  provider.createRefund = () => Promise.resolve({ ok: false, reason: "insufficient_balance" });
  const { deps: d, calls } = deps([refundEvent], {
    providers: new Map([["console", provider]]),
  });
  await createPaymentsWorker(d)();
  // The platform still owes the money, so the books have to say so (money-flows 5c). Leaving it
  // `pending` is how somebody waits for ever.
  assertEquals(calls, ["refund:ref-1:false::insufficient_balance", "complete:20"]);
});

Deno.test("a refund whose charge never reached a gateway is not retried for ever", async () => {
  const { deps: d, calls } = deps([refundEvent], { resolveRefund: () => Promise.resolve(null) });
  await createPaymentsWorker(d)();
  assertEquals(calls, ["fail:20:ERR_REFUND_NOT_FOUND:false"]);
});

Deno.test("a refund goes back through the gateway that took the charge", async () => {
  const other = new ConsolePaymentProvider("development");
  let seen = "";
  other.createRefund = (r) => {
    seen = r.gatewayReference;
    return Promise.resolve({ ok: true, gatewayReference: "x" });
  };
  const { deps: d } = deps([refundEvent], {
    providers: new Map([["console", other]]),
    // The country pack now routes elsewhere; the charge does not care.
    routes: () => Promise.resolve([{ ...ROUTES[0], providers: ["flutterwave"] }]),
  });
  await createPaymentsWorker(d)();
  assertEquals(seen, "FLW-1");
});

Deno.test("an event on an aggregate we claim but do not handle is completed, and said out loud", async () => {
  const seen: string[] = [];
  const { deps: d } = deps([{
    id: 21,
    aggregate: "payment",
    aggregate_id: "x",
    event_type: "payment.expired",
    payload: {},
    attempts: 1,
  }], { log: (level, event) => seen.push(`${level}:${event}`) });
  const result = await createPaymentsWorker(d)();
  assertEquals(result.completed, 1);
  // A refund spent a release being silently completed here (audit T.2), so it is a warning now.
  assertEquals(seen, ["warn:payments.worker.unhandled_event"]);
});
