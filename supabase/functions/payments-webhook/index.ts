import "@supabase/functions-js/edge-runtime.d.ts";
import { withSupabase } from "@supabase/server";
import { createAdminClient } from "@supabase/server/core";
import { log } from "../_shared/log.ts";
import { instrument } from "../_shared/observability.ts";
import { sentryReporterFromEnv } from "../_shared/sentry.ts";
import { ConsolePaymentProvider, type PaymentProvider } from "../_shared/payments/provider.ts";
// The money functions live in `private`, which PostgREST cannot reach and must not. The
// `gateway_*` wrappers in `public` are the seam's only door, granted to `service_role` alone.
import { createPaymentsWebhookHandler } from "./handler.ts";

// Called by a payment gateway, not by an app: no JWT and no API key, authenticated by the
// provider's own signature inside the handler (config.toml sets verify_jwt = false).
//
// Only the console provider is registered. Flutterwave and Paystack adapters are not written:
// their signature schemes and payload shapes are not in the research, and inventing them is what
// CLAUDE.md forbids. Spike S-12 settles them against a sandbox, which needs merchant accounts
// (timeline action 4).
const environment = Deno.env.get("SUSKII_ENV") ?? "development";
const admin = createAdminClient();

const providers = new Map<string, PaymentProvider>([
  [
    "console",
    new ConsolePaymentProvider(environment, Deno.env.get("CONSOLE_WEBHOOK_SECRET") ?? "console-secret"),
  ],
]);

const handler = createPaymentsWebhookHandler({
  providers,
  async ingest(gateway, eventId, signatureValid, payload) {
    const { data, error } = await admin.rpc("gateway_ingest_webhook", {
      p_gateway: gateway,
      p_event_id: eventId,
      p_signature_valid: signatureValid,
      p_payload: payload,
    });
    if (error) throw new Error(error.message);
    return (data as number | null) ?? null;
  },
  async confirmPayment(gateway, reference, amountMinor, feeMinor) {
    const { error } = await admin.rpc("gateway_confirm_payment", {
      p_gateway: gateway,
      p_gateway_reference: reference,
      p_amount_minor: amountMinor,
      p_fee_minor: feeMinor,
    });
    if (error) throw new Error(error.message);
  },
  async recordPayoutResult(gateway, reference, status, feeMinor, reasonKey) {
    const { data, error } = await admin
      .from("payouts")
      .select("id")
      .eq("gateway", gateway)
      .eq("gateway_reference", reference)
      .maybeSingle();
    if (error) throw new Error(error.message);
    if (!data) throw new Error("payout not found for reference");
    const { error: rpcError } = await admin.rpc("gateway_record_payout_result", {
      p_payout_id: data.id,
      p_status: status,
      p_gateway: gateway,
      p_gateway_reference: reference,
      p_fee_minor: feeMinor,
      p_reason_key: reasonKey ?? null,
    });
    if (rpcError) throw new Error(rpcError.message);
  },
  async recordChargeback(gateway, reference, feeMinor) {
    const { data, error } = await admin
      .from("payments")
      .select("id")
      .eq("gateway", gateway)
      .eq("gateway_reference", reference)
      .maybeSingle();
    if (error) throw new Error(error.message);
    if (!data) throw new Error("payment not found for reference");
    const { error: rpcError } = await admin.rpc("gateway_record_chargeback", {
      p_payment_id: data.id,
      p_chargeback_fee_minor: feeMinor,
      p_reason_key: "gateway_chargeback",
    });
    if (rpcError) throw new Error(rpcError.message);
  },
  log,
});

export default {
  fetch: instrument(
    "payments-webhook",
    withSupabase({ auth: "none", cors: "disabled" }, (req) => handler(req)),
    { reporter: sentryReporterFromEnv() },
  ),
};
