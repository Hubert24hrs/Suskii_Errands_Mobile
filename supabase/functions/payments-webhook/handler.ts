import { type PaymentProvider, sha256Hex } from "../_shared/payments/provider.ts";

// The gateway's side of the conversation. The spec's rule, in order: verify the signature, store
// the raw event, de-duplicate on the gateway's own event id, then verify server-side before any
// ledger movement. Nothing here computes money; it calls the database functions that do.
//
// **Always 200, except when we genuinely failed.** A gateway retries anything that is not 2xx,
// and retrying is right for an outage and wrong for a forged event — so a bad signature is
// recorded and acknowledged, and only an error on our side asks for a retry.

export interface WebhookDeps {
  providers: ReadonlyMap<string, PaymentProvider>;
  /** Stores the raw event. Returns null when this event id has already been seen. */
  ingest(
    gateway: string,
    eventId: string,
    signatureValid: boolean,
    payload: unknown,
  ): Promise<number | null>;
  confirmPayment(
    gateway: string,
    reference: string,
    amountMinor: number,
    feeMinor: number,
  ): Promise<void>;
  recordPayoutResult(
    gateway: string,
    reference: string,
    status: "succeeded" | "failed" | "reversed",
    feeMinor: number,
    reasonKey?: string,
  ): Promise<void>;
  recordChargeback(gateway: string, reference: string, feeMinor: number): Promise<void>;
  log(level: "info" | "warn" | "error", event: string, fields?: Record<string, unknown>): void;
}

export function createPaymentsWebhookHandler(deps: WebhookDeps) {
  return async function handle(req: Request): Promise<Response> {
    if (req.method !== "POST") return new Response("method not allowed", { status: 405 });

    // `/payments-webhook/<gateway>` — one route per provider, because their signatures differ and
    // guessing which one sent something is not verification.
    const gateway = new URL(req.url).pathname.split("/").filter(Boolean).pop() ?? "";
    const provider = deps.providers.get(gateway);
    if (!provider) {
      deps.log("warn", "payments.webhook.unknown_gateway", { gateway });
      return new Response("unknown gateway", { status: 404 });
    }

    // The raw body, once. Signatures are over bytes, not over a re-serialised object.
    const raw = await req.text();
    const verification = await provider.verifyWebhook(raw, req.headers);

    // A forged event has no id we can trust — the provider stops at the signature and never
    // parses the body. It still has to be stored, because somebody posting forged events at us is
    // exactly the thing worth having a record of, so it is keyed by a hash of its own body. That
    // also de-duplicates a flood of identical forgeries.
    const eventId = verification.eventId ?? `sha256:${await sha256Hex(raw)}`;

    let payload: unknown = null;
    try {
      payload = JSON.parse(raw);
    } catch {
      payload = { unparsed: true };
    }

    const rowId = await deps.ingest(gateway, eventId, verification.valid, payload);
    if (rowId === null) {
      // The gateway is retrying, not telling us something new.
      deps.log("info", "payments.webhook.duplicate", { gateway, event_id: eventId });
      return new Response("ok", { status: 200 });
    }

    if (!verification.valid) {
      // Stored as evidence and acknowledged: retrying a forged event helps nobody.
      deps.log("warn", "payments.webhook.signature_invalid", { gateway, event_id: eventId });
      return new Response("ok", { status: 200 });
    }

    // Valid, but the provider could not name the event. Stored; not acted on, because an event we
    // cannot de-duplicate by its own id could be processed twice.
    if (!verification.eventId) {
      deps.log("warn", "payments.webhook.no_event_id", { gateway });
      return new Response("ok", { status: 200 });
    }

    const reference = verification.gatewayReference ?? "";
    if (reference === "") {
      deps.log("warn", "payments.webhook.no_reference", { gateway, event_id: eventId });
      return new Response("ok", { status: 200 });
    }

    try {
      switch (verification.kind) {
        case "charge.succeeded": {
          // The spec's second half: a webhook says what happened, this asks whether it really
          // did. Nothing touches the ledger until the gateway confirms against its own records.
          const checked = await provider.verifyCharge(reference, AbortSignal.timeout(8000));
          if (!checked.ok || !checked.settled) {
            deps.log("warn", "payments.webhook.verify_failed", {
              gateway,
              event_id: eventId,
              reason: checked.reason,
            });
            return new Response("ok", { status: 200 });
          }
          await deps.confirmPayment(
            gateway,
            reference,
            checked.amountMinor ?? verification.amountMinor ?? 0,
            checked.feeMinor ?? verification.feeMinor ?? 0,
          );
          break;
        }
        case "transfer.succeeded":
          await deps.recordPayoutResult(gateway, reference, "succeeded", verification.feeMinor ?? 0);
          break;
        case "transfer.failed":
          await deps.recordPayoutResult(gateway, reference, "failed", 0, verification.reason);
          break;
        case "transfer.reversed":
          await deps.recordPayoutResult(gateway, reference, "reversed", 0, verification.reason);
          break;
        case "chargeback":
          await deps.recordChargeback(gateway, reference, verification.feeMinor ?? 0);
          break;
        default:
          // Recorded, not acted on. An event we do not understand is not an error.
          deps.log("info", "payments.webhook.ignored", {
            gateway,
            event_id: eventId,
            kind: verification.kind,
          });
      }
    } catch (error) {
      // Our side failed. This is the one case where a retry is the right answer.
      deps.log("error", "payments.webhook.processing_failed", {
        gateway,
        event_id: eventId,
        reason: error instanceof Error ? error.message : "unknown",
      });
      return new Response("processing failed", { status: 500 });
    }

    return new Response("ok", { status: 200 });
  };
}
