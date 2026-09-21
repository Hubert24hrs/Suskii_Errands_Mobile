import "@supabase/functions-js/edge-runtime.d.ts";
import { withSupabase } from "@supabase/server";
import { createAdminClient } from "@supabase/server/core";
import { log } from "../_shared/log.ts";
import { instrument } from "../_shared/observability.ts";
import { sentryReporterFromEnv } from "../_shared/sentry.ts";
import { ConsolePaymentProvider, type PaymentProvider } from "../_shared/payments/provider.ts";
import { type CountryPaymentRoute, routesFromRows } from "../_shared/payments/routing.ts";
import { type ClaimedEvent, createPaymentsWorker } from "./handler.ts";

// Drains the outbox and calls a gateway. Invoked on a schedule with the named secret API key
// "worker", so the key can be rotated without touching anything else.
//
// **`resolvePayoutTarget` is deliberately absent.** A transfer needs the real account number, and
// `payout_accounts.account_ciphertext` is envelope-encrypted with a key in GCP KMS (ADR-0007)
// which does not exist yet — no GCP billing account (timeline action 1). The worker therefore
// refuses transfers with a retryable `ERR_PAYOUT_KEY_UNAVAILABLE` rather than pretending, and
// checkouts, which need no account number, work today.
const environment = Deno.env.get("SUSKII_ENV") ?? "development";
const admin = createAdminClient();

const providers = new Map<string, PaymentProvider>([
  ["console", new ConsolePaymentProvider(environment)],
]);

let cachedRoutes: { at: number; routes: CountryPaymentRoute[] } | null = null;

async function routes(): Promise<CountryPaymentRoute[]> {
  if (cachedRoutes && Date.now() - cachedRoutes.at < 60_000) return cachedRoutes.routes;
  const { data, error } = await admin
    .from("countries")
    .select("code, config")
    .in("status", ["beta", "live"]);
  if (error) throw new Error(error.message);
  cachedRoutes = { at: Date.now(), routes: routesFromRows(data ?? []) };
  return cachedRoutes.routes;
}

const run = createPaymentsWorker({
  providers,
  routes,
  async claim(aggregates, limit) {
    const { data, error } = await admin.rpc("gateway_claim_outbox", {
      p_aggregates: aggregates,
      p_limit: limit,
    });
    if (error) throw new Error(error.message);
    return (data ?? []) as ClaimedEvent[];
  },
  async complete(id) {
    const { error } = await admin.rpc("gateway_complete_outbox", { p_id: id });
    if (error) throw new Error(error.message);
  },
  async fail(id, reasonKey, retry) {
    const { error } = await admin.rpc("gateway_fail_outbox", {
      p_id: id,
      p_reason_key: reasonKey,
      p_retry: retry,
    });
    if (error) throw new Error(error.message);
  },
  async recordCheckout(paymentId, gateway, reference, checkoutUrl) {
    const { error } = await admin.rpc("gateway_record_checkout", {
      p_payment_id: paymentId,
      p_gateway: gateway,
      p_gateway_reference: reference,
      p_checkout_url: checkoutUrl === "" ? null : checkoutUrl,
    });
    if (error) throw new Error(error.message);
  },
  async recordPayoutResult(payoutId, status, gateway, reference) {
    const { error } = await admin.rpc("gateway_record_payout_result", {
      p_payout_id: payoutId,
      p_status: status,
      p_gateway: gateway,
      p_gateway_reference: reference,
      p_fee_minor: 0,
      p_reason_key: null,
    });
    if (error) throw new Error(error.message);
  },
  async recordAccountVerification(accountId, verified, holderName) {
    const { error } = await admin.rpc("gateway_record_account_verification", {
      p_payout_account_id: accountId,
      p_verified: verified,
      p_holder_name: holderName ?? null,
    });
    if (error) throw new Error(error.message);
  },
  log,
});

export default {
  fetch: instrument(
    "payments-worker",
    withSupabase({ auth: "secret:worker", cors: "disabled" }, async () => {
      const result = await run();
      return new Response(JSON.stringify(result), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    }),
    { reporter: sentryReporterFromEnv() },
  ),
};
