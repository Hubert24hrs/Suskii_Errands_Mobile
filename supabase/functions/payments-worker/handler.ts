import type { PaymentProvider } from "../_shared/payments/provider.ts";
import { type CountryPaymentRoute, providersFor, routeFor } from "../_shared/payments/routing.ts";

// The outbox, drained. Three events need somebody to call a gateway:
//
//   payment.requested             → create a checkout, write the reference back
//   payout.requested              → create a transfer, write the reference back
//   payout_account.registered     → name enquiry, write the answer back
//
// Nothing here decides anything about money. It takes an event, calls a provider, and hands the
// answer to a database function that does the deciding — which is why a worker that dies halfway
// loses a call, never a posting.
//
// **An event is claimed, not read.** Two workers polling the same table would otherwise both see
// the same row and both charge somebody; `gateway_claim_outbox` uses `FOR UPDATE SKIP LOCKED`.

export interface ClaimedEvent {
  id: number;
  aggregate: string;
  aggregate_id: string;
  event_type: string;
  payload: Record<string, unknown>;
  attempts: number;
}

/** An account number, decrypted by the caller. The worker's KMS key, not the adapter's business. */
export interface PayoutTarget {
  rail: "bank" | "mobile_money";
  institutionCode: string;
  accountNumber: string;
  holderName: string;
  countryCode: string;
}

export interface WorkerDeps {
  providers: ReadonlyMap<string, PaymentProvider>;
  routes(): Promise<CountryPaymentRoute[]>;
  claim(aggregates: string[], limit: number): Promise<ClaimedEvent[]>;
  complete(id: number): Promise<void>;
  fail(id: number, reasonKey: string, retry: boolean): Promise<void>;
  recordCheckout(
    paymentId: string,
    gateway: string,
    reference: string,
    checkoutUrl: string,
  ): Promise<void>;
  recordPayoutResult(
    payoutId: string,
    status: "submitted" | "pending",
    gateway: string,
    reference: string,
  ): Promise<void>;
  recordAccountVerification(
    accountId: string,
    verified: boolean,
    holderName?: string,
  ): Promise<void>;
  /** Decrypts `payout_accounts.account_ciphertext`. Absent until the KMS key exists. */
  resolvePayoutTarget?(payoutId: string): Promise<PayoutTarget | null>;
  log(level: "info" | "warn" | "error", event: string, fields?: Record<string, unknown>): void;
}

export interface WorkerResult {
  claimed: number;
  completed: number;
  failed: number;
}

const TIMEOUT_MS = 10_000;

export function createPaymentsWorker(deps: WorkerDeps) {
  return async function run(limit = 25): Promise<WorkerResult> {
    const events = await deps.claim(["payment", "payout"], limit);
    const routes = await deps.routes();
    let completed = 0;
    let failed = 0;

    for (const event of events) {
      try {
        const handled = await dispatch(deps, routes, event);
        if (handled === "done") {
          await deps.complete(event.id);
          completed++;
        } else if (handled === "ignored") {
          // Not ours to act on — a notification for somebody else's worker. Marked done so it
          // stops being claimed, rather than retried for ever.
          await deps.complete(event.id);
          completed++;
        } else {
          await deps.fail(event.id, handled.reason, handled.retry);
          failed++;
        }
      } catch (error) {
        deps.log("error", "payments.worker.unhandled", {
          event_id: event.id,
          event_type: event.event_type,
          reason: error instanceof Error ? error.message : "unknown",
        });
        await deps.fail(event.id, "ERR_INTERNAL", true);
        failed++;
      }
    }

    return { claimed: events.length, completed, failed };
  };
}

type Outcome = "done" | "ignored" | { reason: string; retry: boolean };

async function dispatch(
  deps: WorkerDeps,
  routes: CountryPaymentRoute[],
  event: ClaimedEvent,
): Promise<Outcome> {
  switch (event.event_type) {
    case "payment.requested":
      return await doCheckout(deps, routes, event);
    case "payout.requested":
      return await doTransfer(deps, routes, event);
    case "payout_account.registered":
      return await doNameEnquiry(deps, routes, event);
    default:
      return "ignored";
  }
}

function pickProvider(
  deps: WorkerDeps,
  routes: CountryPaymentRoute[],
  countryCode: string,
  options: { method?: string; amountMinor?: number; payout?: boolean },
): PaymentProvider | { reason: string } {
  const route = routeFor(countryCode, routes);
  if (!route) return { reason: "ERR_COUNTRY_NOT_SUPPORTED" };
  const names = options.payout && route.payoutProviders.length > 0
    ? route.payoutProviders
    : providersFor(route, options);
  for (const name of names) {
    const provider = deps.providers.get(name);
    if (provider) return provider;
  }
  // A country pack naming a provider nobody has implemented is a configuration mistake, and it
  // should look like one rather than like a gateway outage.
  return { reason: "ERR_NO_PROVIDER_CONFIGURED" };
}

async function doCheckout(
  deps: WorkerDeps,
  routes: CountryPaymentRoute[],
  event: ClaimedEvent,
): Promise<Outcome> {
  const p = event.payload;
  const country = String(p.country_code ?? "");
  const amountMinor = Number(p.amount_minor ?? 0);
  const chosen = pickProvider(deps, routes, country, {
    method: typeof p.method === "string" ? p.method : undefined,
    amountMinor,
  });
  if ("reason" in chosen) return { reason: chosen.reason, retry: false };

  const result = await chosen.createCheckout({
    paymentId: String(p.payment_id ?? event.aggregate_id),
    amountMinor,
    currency: String(p.currency ?? ""),
    countryCode: country,
    method: typeof p.method === "string" ? p.method : undefined,
    reference: `suskii-${p.payment_id}`,
    customerRef: String(p.payer_id ?? ""),
  }, AbortSignal.timeout(TIMEOUT_MS));

  if (!result.ok || !result.gatewayReference) {
    return { reason: result.reason ?? "ERR_PAYMENT_FAILED", retry: true };
  }
  await deps.recordCheckout(
    String(p.payment_id ?? event.aggregate_id),
    chosen.name,
    result.gatewayReference,
    result.checkoutUrl ?? "",
  );
  deps.log("info", "payments.worker.checkout_created", {
    payment_id: p.payment_id,
    provider: chosen.name,
  });
  return "done";
}

async function doTransfer(
  deps: WorkerDeps,
  routes: CountryPaymentRoute[],
  event: ClaimedEvent,
): Promise<Outcome> {
  const p = event.payload;
  const payoutId = String(p.payout_id ?? event.aggregate_id);

  if (!deps.resolvePayoutTarget) {
    // No KMS key, so no account number, so no transfer. Retryable: the key is a deployment
    // concern, and the event should still be waiting when it arrives.
    return { reason: "ERR_PAYOUT_KEY_UNAVAILABLE", retry: true };
  }
  const target = await deps.resolvePayoutTarget(payoutId);
  if (!target) return { reason: "ERR_PAYOUT_ACCOUNT_NOT_FOUND", retry: false };

  const chosen = pickProvider(deps, routes, target.countryCode, { payout: true });
  if ("reason" in chosen) return { reason: chosen.reason, retry: false };

  const result = await chosen.createTransfer({
    payoutId,
    amountMinor: Number(p.amount_minor ?? 0),
    currency: String(p.currency ?? ""),
    countryCode: target.countryCode,
    rail: target.rail,
    institutionCode: target.institutionCode,
    accountNumber: target.accountNumber,
    holderName: target.holderName,
    reference: `suskii-payout-${payoutId}`,
  }, AbortSignal.timeout(TIMEOUT_MS));

  if (!result.ok || !result.gatewayReference) {
    return { reason: result.reason ?? "ERR_INTERNAL", retry: true };
  }
  // Submitted or pending only. A transfer is not successful because we asked for it — that
  // arrives by webhook, hours later (REPORT §3.1).
  await deps.recordPayoutResult(
    payoutId,
    result.status === "submitted" ? "submitted" : "pending",
    chosen.name,
    result.gatewayReference,
  );
  return "done";
}

async function doNameEnquiry(
  deps: WorkerDeps,
  routes: CountryPaymentRoute[],
  event: ClaimedEvent,
): Promise<Outcome> {
  const p = event.payload;
  const accountId = String(p.payout_account_id ?? event.aggregate_id);

  if (!deps.resolvePayoutTarget) {
    return { reason: "ERR_PAYOUT_KEY_UNAVAILABLE", retry: true };
  }
  const target = await deps.resolvePayoutTarget(accountId);
  if (!target) return { reason: "ERR_PAYOUT_ACCOUNT_NOT_FOUND", retry: false };

  const chosen = pickProvider(deps, routes, target.countryCode, { payout: true });
  if ("reason" in chosen) return { reason: chosen.reason, retry: false };

  const result = await chosen.resolveAccount({
    countryCode: target.countryCode,
    rail: target.rail,
    institutionCode: target.institutionCode,
    accountNumber: target.accountNumber,
  }, AbortSignal.timeout(TIMEOUT_MS));

  // A negative answer is an answer: the account is recorded as unverified and the person is not
  // left waiting for something that already happened.
  await deps.recordAccountVerification(accountId, result.ok, result.holderName);
  return "done";
}
