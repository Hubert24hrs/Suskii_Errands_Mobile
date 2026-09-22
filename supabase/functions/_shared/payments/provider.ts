// Payment provider abstraction (spec phase 5, "PaymentProvider abstraction; Flutterwave and
// Stripe Connect integrations with per-country routing").
//
// The abstraction is a separate deliverable from the integrations, and this is the abstraction.
// **The Flutterwave and Paystack adapters are deliberately not written.** Their endpoint paths,
// payload shapes, signature header names and auth schemes are not in `docs/research/REPORT.md`
// §3 — the research captured pricing, fee-bearer settings, payout rails and the webhook *rules*,
// which is what a design needs, not what an adapter needs. Writing them from memory is exactly
// what CLAUDE.md forbids, and an adapter that cannot be run against a sandbox is rewritten the
// first time somebody does run it. Spike **S-12** is the mechanism: it needs merchant accounts
// (timeline action 4), and it settles the shapes at the same time as it proves the flow.
//
// What is here is everything that is ours rather than theirs: the interface each adapter fills
// in, the console provider that lets the whole path be exercised, and the rules the adapters must
// obey — verify the signature, store the raw event, de-duplicate on the gateway's own event id,
// and verify server-side before any ledger movement (spec; REPORT §3.1).

/** A charge, from our side. Amounts are integer minor units, never floats (spec money_rules). */
export interface CheckoutRequest {
  paymentId: string;
  amountMinor: number;
  currency: string;
  countryCode: string;
  /** `card`, `bank_transfer`, `mobile_money`… whatever the country pack routes to. */
  method?: string;
  /** Our own reference, which must survive into the gateway's records. */
  reference: string;
  /** Opaque to the adapter: a customer identifier that is not a phone number or an email. */
  customerRef: string;
}

export interface CheckoutResult {
  ok: boolean;
  gatewayReference?: string;
  checkoutUrl?: string;
  /** Stable, non-personal failure reason for logs and metrics. */
  reason?: string;
}

/**
 * A transfer out. The account number arrives **decrypted by the caller**, never by the adapter:
 * `payout_accounts.account_ciphertext` is envelope-encrypted (ADR-0007) and the key lives in the
 * worker's KMS, so decryption is a boundary concern and not a vendor one.
 */
export interface TransferRequest {
  payoutId: string;
  amountMinor: number;
  currency: string;
  countryCode: string;
  rail: "bank" | "mobile_money";
  institutionCode: string;
  accountNumber: string;
  holderName: string;
  reference: string;
}

export interface TransferResult {
  ok: boolean;
  gatewayReference?: string;
  /** Transfers start pending and resolve by webhook hours later (REPORT §3.1). */
  status?: "submitted" | "pending" | "succeeded" | "failed";
  feeMinor?: number;
  reason?: string;
}

/** A bank name enquiry: does this account exist, and whose is it? */
export interface AccountResolveRequest {
  countryCode: string;
  rail: "bank" | "mobile_money";
  institutionCode: string;
  accountNumber: string;
}

export interface AccountResolveResult {
  ok: boolean;
  holderName?: string;
  reason?: string;
}

/**
 * A refund, from our side. The gateway is told which charge to reverse and by how much; a partial
 * refund is the normal case, because a dispute can end in one.
 */
export interface RefundRequest {
  refundId: string;
  /** The charge being reversed, as the gateway knows it. */
  gatewayReference: string;
  amountMinor: number;
  currency: string;
  /** Stable, non-personal reason for the gateway's own records. */
  reasonCode: string;
}

export interface RefundResult {
  ok: boolean;
  gatewayReference?: string;
  reason?: string;
}

export interface WebhookVerification {
  /** False means the signature did not check out. The event is still stored, as evidence. */
  valid: boolean;
  /** The gateway's own event id, which is what de-duplication is keyed on. */
  eventId?: string;
  /** What happened, normalised: our side does not branch on vendor vocabulary. */
  kind?:
    | "charge.succeeded"
    | "charge.failed"
    | "transfer.succeeded"
    | "transfer.failed"
    | "transfer.reversed"
    | "refund.succeeded"
    | "chargeback"
    | "other";
  gatewayReference?: string;
  amountMinor?: number;
  feeMinor?: number;
  reason?: string;
}

/**
 * The server-side verify the spec requires after a webhook and before any ledger movement. A
 * webhook says what happened; this asks the gateway whether it really did.
 */
export interface ChargeVerification {
  ok: boolean;
  settled: boolean;
  amountMinor?: number;
  feeMinor?: number;
  reason?: string;
}

export interface PaymentProvider {
  readonly name: string;
  createCheckout(request: CheckoutRequest, signal: AbortSignal): Promise<CheckoutResult>;
  createTransfer(request: TransferRequest, signal: AbortSignal): Promise<TransferResult>;
  createRefund(request: RefundRequest, signal: AbortSignal): Promise<RefundResult>;
  resolveAccount(
    request: AccountResolveRequest,
    signal: AbortSignal,
  ): Promise<AccountResolveResult>;
  /** Synchronous where the algorithm allows it; the raw body must not be parsed first. */
  verifyWebhook(rawBody: string, headers: Headers): Promise<WebhookVerification>;
  verifyCharge(gatewayReference: string, signal: AbortSignal): Promise<ChargeVerification>;
}

/**
 * Development provider. Accepts everything, moves nothing, and **refuses to run in production**,
 * so a country pack that still routes to `console` fails loudly instead of silently telling us a
 * customer paid when nobody did.
 *
 * Its webhook signature is a plain HMAC-SHA256 of the body in an `x-console-signature` header —
 * our own scheme, so that the whole path from webhook to ledger can be tested end to end without
 * pretending to know anybody else's.
 */
export class ConsolePaymentProvider implements PaymentProvider {
  readonly name = "console";

  constructor(
    private readonly environment: string,
    private readonly webhookSecret: string = "console-secret",
  ) {}

  private disabled(): { ok: false; reason: string } | null {
    return this.environment === "production" ? { ok: false, reason: "console_provider_disabled_in_production" } : null;
  }

  createCheckout(request: CheckoutRequest): Promise<CheckoutResult> {
    const off = this.disabled();
    if (off) return Promise.resolve(off);
    const ref = `console-${request.paymentId}`;
    return Promise.resolve({
      ok: true,
      gatewayReference: ref,
      // Deliberately not a real URL: nothing should try to open it.
      checkoutUrl: `https://checkout.invalid/${ref}`,
    });
  }

  createTransfer(request: TransferRequest): Promise<TransferResult> {
    const off = this.disabled();
    if (off) return Promise.resolve(off);
    return Promise.resolve({
      ok: true,
      gatewayReference: `console-payout-${request.payoutId}`,
      status: "pending",
      feeMinor: 0,
    });
  }

  createRefund(request: RefundRequest): Promise<RefundResult> {
    const off = this.disabled();
    if (off) return Promise.resolve(off);
    return Promise.resolve({
      ok: true,
      gatewayReference: `console-refund-${request.refundId}`,
    });
  }

  resolveAccount(request: AccountResolveRequest): Promise<AccountResolveResult> {
    const off = this.disabled();
    if (off) return Promise.resolve(off);
    // An account number ending in 0 does not resolve, so the failure path has something to test.
    if (request.accountNumber.endsWith("0")) {
      return Promise.resolve({ ok: false, reason: "account_not_found" });
    }
    return Promise.resolve({ ok: true, holderName: "CONSOLE ACCOUNT" });
  }

  async verifyWebhook(rawBody: string, headers: Headers): Promise<WebhookVerification> {
    if (this.environment === "production") {
      return { valid: false, reason: "console_provider_disabled_in_production" };
    }
    const provided = headers.get("x-console-signature") ?? "";
    const expected = await hmacSha256Hex(this.webhookSecret, rawBody);
    if (!timingSafeEqual(provided, expected)) {
      return { valid: false, reason: "signature_mismatch" };
    }
    let parsed: Record<string, unknown>;
    try {
      parsed = JSON.parse(rawBody) as Record<string, unknown>;
    } catch {
      return { valid: false, reason: "body_not_json" };
    }
    return {
      valid: true,
      eventId: typeof parsed.event_id === "string" ? parsed.event_id : undefined,
      kind: normaliseKind(parsed.kind),
      gatewayReference: typeof parsed.reference === "string" ? parsed.reference : undefined,
      amountMinor: typeof parsed.amount_minor === "number" ? parsed.amount_minor : undefined,
      feeMinor: typeof parsed.fee_minor === "number" ? parsed.fee_minor : undefined,
    };
  }

  verifyCharge(_gatewayReference: string): Promise<ChargeVerification> {
    const off = this.disabled();
    if (off) return Promise.resolve({ ok: false, settled: false, reason: off.reason });
    return Promise.resolve({ ok: true, settled: true });
  }
}

const KINDS: ReadonlySet<string> = new Set([
  "charge.succeeded",
  "charge.failed",
  "transfer.succeeded",
  "transfer.failed",
  "transfer.reversed",
  "refund.succeeded",
  "chargeback",
]);

function normaliseKind(value: unknown): WebhookVerification["kind"] {
  return typeof value === "string" && KINDS.has(value) ? value as WebhookVerification["kind"] : "other";
}

/** Used to key an event whose id we could not read, so it is still stored and de-duplicated. */
export async function sha256Hex(body: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(body));
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

export async function hmacSha256Hex(secret: string, body: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body));
  return Array.from(new Uint8Array(signature))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/** Constant time in the length-equal case, which is the one an attacker controls. */
export function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export type PaymentProviderRegistry = ReadonlyMap<string, PaymentProvider>;
