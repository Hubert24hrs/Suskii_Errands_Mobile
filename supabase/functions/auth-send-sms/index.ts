import "@supabase/functions-js/edge-runtime.d.ts";
import { withSupabase } from "@supabase/server";
import { createAdminClient } from "@supabase/server/core";
import { ConsoleSmsProvider, type SmsProvider } from "../_shared/sms/provider.ts";
import { CachedRouteSource } from "../_shared/sms/routing.ts";
import { createSendSmsHandler } from "./handler.ts";

// Called by Supabase Auth, not by apps: no JWT or API key, authenticated by the Standard
// Webhooks signature inside the handler (config.toml sets verify_jwt = false).
const environment = Deno.env.get("SUSKII_ENV") ?? "development";
const admin = createAdminClient();

const providers = new Map<string, SmsProvider>([
  ["console", new ConsoleSmsProvider(environment)],
]);

const routes = new CachedRouteSource(async () => {
  const { data, error } = await admin
    .from("countries")
    .select("code, calling_code, config")
    .in("status", ["beta", "live"]);
  if (error) throw new Error(error.message);
  return data ?? [];
});

const handler = createSendSmsHandler({
  hookSecrets: Deno.env.get("SEND_SMS_HOOK_SECRETS"),
  routes,
  providers,
  androidAppHash: Deno.env.get("ANDROID_SMS_RETRIEVER_HASH"),
});

export default {
  fetch: withSupabase({ auth: "none", cors: "disabled" }, (req) => handler(req)),
};
