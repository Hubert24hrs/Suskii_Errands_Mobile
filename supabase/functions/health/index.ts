import "@supabase/functions-js/edge-runtime.d.ts";
import { withSupabase } from "@supabase/server";
import { instrument } from "../_shared/observability.ts";
import { sentryReporterFromEnv } from "../_shared/sentry.ts";
import { createHealthHandler, type HealthSnapshot, type SafetyAlarm } from "./handler.ts";

// Called by Cloud Monitoring uptime checks with a named secret API key ("monitoring"), so the
// key can be rotated without touching any other caller.
export default {
  fetch: instrument(
    "health",
    withSupabase({ auth: "secret:monitoring", cors: "disabled" }, (req, ctx) =>
      createHealthHandler({
        release: Deno.env.get("SUSKII_RELEASE"),
        async getHealth() {
          const { data, error } = await ctx.supabaseAdmin.rpc("get_health");
          if (error) throw new Error(error.message);
          return data as HealthSnapshot;
        },
        async getSafetyAlarm() {
          const { data, error } = await ctx.supabaseAdmin.rpc("get_safety_alarm");
          if (error) throw new Error(error.message);
          return data as SafetyAlarm;
        },
      })(req)),
    { reporter: sentryReporterFromEnv() },
  ),
};
