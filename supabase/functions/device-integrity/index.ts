import "@supabase/functions-js/edge-runtime.d.ts";
import { withSupabase } from "@supabase/server";
import { createGoogleAccessTokenSource } from "../_shared/integrity/google_auth.ts";
import { GooglePlayIntegrityDecoder } from "../_shared/integrity/play_integrity.ts";
import { log } from "../_shared/log.ts";
import { instrument } from "../_shared/observability.ts";
import { sentryReporterFromEnv } from "../_shared/sentry.ts";
import { createDeviceIntegrityHandler, type IntegrityStore, NonceRejectedError } from "./handler.ts";

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

const playDecoder = playDecoderFromEnv();
const androidPackageName = Deno.env.get("ANDROID_PACKAGE_NAME");

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
      return createDeviceIntegrityHandler({ store, playDecoder, androidPackageName })(req, ctx.userClaims!.id);
    }),
    { reporter: sentryReporterFromEnv() },
  ),
};
