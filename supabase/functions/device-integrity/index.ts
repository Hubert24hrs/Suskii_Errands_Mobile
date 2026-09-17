import "@supabase/functions-js/edge-runtime.d.ts";
import { withSupabase } from "@supabase/server";
import type { AppAttestPolicy } from "../_shared/integrity/app_attest.ts";
import { createGoogleAccessTokenSource } from "../_shared/integrity/google_auth.ts";
import { GooglePlayIntegrityDecoder } from "../_shared/integrity/play_integrity.ts";
import { log } from "../_shared/log.ts";
import { instrument } from "../_shared/observability.ts";
import { sentryReporterFromEnv } from "../_shared/sentry.ts";
import {
  type AppAttestStore,
  createDeviceIntegrityHandler,
  type IntegrityStore,
  NonceRejectedError,
} from "./handler.ts";

const PLAY_INTEGRITY_SCOPE = "https://www.googleapis.com/auth/playintegrity";

function playDecoderFromEnv(): GooglePlayIntegrityDecoder | undefined {
  const raw = Deno.env.get("GOOGLE_PLAY_INTEGRITY_SERVICE_ACCOUNT");
  if (!raw) return undefined;
  try {
    return new GooglePlayIntegrityDecoder(createGoogleAccessTokenSource(JSON.parse(raw), PLAY_INTEGRITY_SCOPE));
  } catch {
    log("error", "device_integrity.bad_service_account_secret");
    return undefined;
  }
}

// IOS_APP_ID is "<team id>.<bundle id>". APP_ATTEST_ENVIRONMENT must match the app's
// com.apple.developer.devicecheck.appattest-environment entitlement (TestFlight and App Store
// builds use production). APP_ATTEST_VALIDATION_CATEGORIES lists accepted launch categories:
// 2 TestFlight, 3 development signing, 4 App Store.
function appAttestPolicyFromEnv(): AppAttestPolicy | undefined {
  const appId = Deno.env.get("IOS_APP_ID");
  if (!appId) return undefined;
  const environment = Deno.env.get("APP_ATTEST_ENVIRONMENT") === "development" ? "development" : "production";
  const categories =
    (Deno.env.get("APP_ATTEST_VALIDATION_CATEGORIES") ?? (environment === "production" ? "4" : "2,3,4"))
      .split(",").map((c) => Number(c.trim())).filter((c) => Number.isInteger(c) && c > 0);
  if (!/^[A-Z0-9]{10}\.[A-Za-z0-9.-]+$/.test(appId) || categories.length === 0) {
    log("error", "device_integrity.bad_app_attest_config");
    return undefined;
  }
  return { appId, environment, allowedValidationCategories: categories };
}

const playDecoder = playDecoderFromEnv();
const androidPackageName = Deno.env.get("ANDROID_PACKAGE_NAME");
const appAttestPolicy = appAttestPolicyFromEnv();

export default {
  fetch: instrument(
    "device-integrity",
    withSupabase({ auth: "user" }, (req, ctx) => {
      // Verdicts are written with the admin client: user_devices.integrity_verdict has no client
      // grant, so a device can never mark itself trustworthy.
      const admin = ctx.supabaseAdmin;
      const store: IntegrityStore = {
        async consumeNonce(nonce, userId) {
          const { data, error } = await admin.rpc("consume_integrity_nonce", { p_nonce: nonce, p_user_id: userId });
          if (error) {
            if (error.message?.includes("ERR_INTEGRITY_NONCE_INVALID")) throw new NonceRejectedError();
            throw new Error(error.message);
          }
          return { deviceId: data.device_id, purpose: data.purpose, platform: data.platform };
        },
        async saveVerdict(deviceId, userId, verdict) {
          const { error } = await admin
            .from("user_devices")
            .update({ integrity_verdict: verdict, last_seen_at: new Date().toISOString() })
            .eq("id", deviceId)
            .eq("user_id", userId);
          if (error) throw new Error(error.message);
        },
      };
      const appAttestStore: AppAttestStore = {
        async registerKey(input) {
          const { data, error } = await admin.rpc("app_attest_register_key", {
            p_user_id: input.userId,
            p_device_id: input.deviceId,
            p_key_id: input.keyId,
            p_public_key: input.publicKey,
            p_receipt: input.receipt,
            p_environment: input.environment,
            p_validation_category: input.validationCategory ?? null,
            p_bundle_version: input.bundleVersion ?? null,
          });
          if (error) throw new Error(error.message);
          return data === true;
        },
        async keyForAssertion(userId, deviceId, keyId) {
          const { data, error } = await admin.rpc("app_attest_key_for_assertion", {
            p_user_id: userId,
            p_device_id: deviceId,
            p_key_id: keyId,
          });
          if (error) throw new Error(error.message);
          if (!data) return null;
          return { publicKey: data.public_key, signCount: Number(data.sign_count), environment: data.environment };
        },
        async recordAssertion(userId, keyId, counter) {
          const { data, error } = await admin.rpc("app_attest_record_assertion", {
            p_user_id: userId,
            p_key_id: keyId,
            p_counter: counter,
          });
          if (error) throw new Error(error.message);
          return data === true;
        },
      };
      return createDeviceIntegrityHandler({
        store,
        playDecoder,
        androidPackageName,
        appAttest: appAttestPolicy ? { store: appAttestStore, policy: appAttestPolicy } : undefined,
      })(req, ctx.userClaims!.id);
    }),
    { reporter: sentryReporterFromEnv() },
  ),
};
