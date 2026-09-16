// Supabase Auth Send SMS Hook (PRD SH-02; S-09; R-31).
// Auth POSTs { user, sms: { otp } } signed with Standard Webhooks; success is an empty 200,
// failure is { error: { http_code, message } }. Auth retries 429 and 503 within a 5 s budget,
// which would send duplicate OTPs, so this handler never returns either.

import { hookError, json } from "../_shared/http.ts";
import { log, maskPhone } from "../_shared/log.ts";
import { verifyWebhook, WebhookVerificationError } from "../_shared/standard_webhooks.ts";
import { sendWithFailover } from "../_shared/sms/failover.ts";
import { isValidOtp, otpMessage } from "../_shared/sms/message.ts";
import type { ProviderRegistry } from "../_shared/sms/provider.ts";
import { normalisePhoneDigits, routeFor, type RouteSource } from "../_shared/sms/routing.ts";

export interface SendSmsDeps {
  hookSecrets: string | undefined;
  routes: RouteSource;
  providers: ProviderRegistry;
  androidAppHash?: string;
  /** Share of Auth's 5 s hook budget spent on provider attempts. */
  deadlineMs?: number;
  now?: () => number;
}

interface SendSmsPayload {
  user?: { id?: string; phone?: string };
  sms?: { otp?: unknown };
}

export function createSendSmsHandler(deps: SendSmsDeps): (req: Request) => Promise<Response> {
  return async (req: Request): Promise<Response> => {
    if (req.method !== "POST") return hookError(405, "ERR_METHOD_NOT_ALLOWED");
    if (!deps.hookSecrets) {
      log("error", "send_sms.misconfigured", { missing: "SEND_SMS_HOOK_SECRETS" });
      return hookError(500, "ERR_HOOK_MISCONFIGURED");
    }

    const rawBody = await req.text();
    let payload: SendSmsPayload;
    try {
      payload = (await verifyWebhook(rawBody, req.headers, deps.hookSecrets)) as SendSmsPayload;
    } catch (err) {
      const reason = err instanceof WebhookVerificationError ? err.message : "verification_error";
      log("warn", "send_sms.signature_rejected", { reason });
      return hookError(401, "ERR_INVALID_SIGNATURE");
    }

    const phone = normalisePhoneDigits(payload.user?.phone ?? "");
    const otp = payload.sms?.otp;
    if (phone.length < 8 || !isValidOtp(otp)) {
      log("warn", "send_sms.bad_payload", { user_id: payload.user?.id });
      return hookError(400, "ERR_INVALID_PAYLOAD");
    }

    let route;
    try {
      route = routeFor(phone, await deps.routes.load());
    } catch (err) {
      log("error", "send_sms.routes_unavailable", { error: String(err) });
      return hookError(500, "ERR_SMS_ROUTING_UNAVAILABLE");
    }
    // The before-user-created hook already refuses unsupported numbers at sign-up; this also
    // covers existing users changing their number (R-31: never pay for SMS we don't route).
    if (!route) {
      log("warn", "send_sms.country_not_supported", { phone: maskPhone(phone) });
      return hookError(400, "ERR_COUNTRY_NOT_SUPPORTED");
    }
    if (route.providers.length === 0) {
      log("error", "send_sms.no_providers", { country: route.countryCode });
      return hookError(500, "ERR_SMS_ROUTING_UNAVAILABLE");
    }

    const result = await sendWithFailover(
      route.providers,
      deps.providers,
      phone,
      otpMessage(otp, deps.androidAppHash),
      { deadlineMs: deps.deadlineMs ?? 4_000, now: deps.now },
    );

    const fields = {
      country: route.countryCode,
      phone: maskPhone(phone),
      provider: result.provider,
      attempts: result.attempts,
    };
    if (!result.ok) {
      log("error", "send_sms.delivery_failed", fields);
      return hookError(500, "ERR_SMS_DELIVERY_FAILED");
    }
    log("info", "send_sms.sent", fields);
    return json({}, 200);
  };
}
