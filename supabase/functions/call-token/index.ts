import "@supabase/functions-js/edge-runtime.d.ts";
import { withSupabase } from "@supabase/server";
import { log } from "../_shared/log.ts";
import { instrument } from "../_shared/observability.ts";
import { sentryReporterFromEnv } from "../_shared/sentry.ts";
import { createCallTokenHandler, RpcError } from "./handler.ts";
import { credentialsFromEnv, roomToken } from "./token.ts";

// In-app masked calls over LiveKit Cloud. Called by the app with the caller's session; the
// database calls are made as that person, so the job window and the one-call-per-job rule apply
// exactly as they do to the app. LIVEKIT_URL, LIVEKIT_API_KEY and LIVEKIT_API_SECRET come from the
// `livekit-credentials` secret; without them calls answer 503 ERR_FEATURE_UNAVAILABLE.

const WIRE_CODE = /ERR_[A-Z0-9_]+/;
const credentials = credentialsFromEnv((k) => Deno.env.get(k));

export default {
  fetch: instrument(
    "call-token",
    withSupabase({ auth: "user" }, (req, ctx) =>
      createCallTokenHandler({
        async rpc(fn, args) {
          const { data, error } = await ctx.supabase.rpc(fn, args);
          if (error) {
            const code = error.message?.match(WIRE_CODE)?.[0];
            if (code) throw new RpcError(code);
            throw new Error(error.message);
          }
          return data;
        },
        credentials,
        sign: (c, room, identity) => roomToken(c, room, identity),
        log,
      })(req)),
    { reporter: sentryReporterFromEnv() },
  ),
};
