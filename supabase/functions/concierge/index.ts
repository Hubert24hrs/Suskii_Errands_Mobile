import "@supabase/functions-js/edge-runtime.d.ts";
import { withSupabase } from "@supabase/server";
import { parseServiceAccount, ServiceAccountTokens } from "../_shared/google/access_token.ts";
import { type GenerateResult, type LlmGateway, LlmUnavailable, VertexGemini } from "../_shared/ai/llm.ts";
import { log } from "../_shared/log.ts";
import { instrument } from "../_shared/observability.ts";
import { sentryReporterFromEnv } from "../_shared/sentry.ts";
import { createConciergeHandler, RpcError } from "./handler.ts";

// Ask Suskii (ADR-0024). Called by the app with the customer's session; every database call is
// made as that customer, so RLS and the function grants apply exactly as they do to the app.
//
// Vertex is reached with the `concierge-vertex` service account (roles/aiplatform.user only),
// whose key is VERTEX_SERVICE_ACCOUNT_JSON. Without it the function still answers: every turn
// hands the customer to the form, which is the same thing a switched-off concierge does.

const WIRE_CODE = /ERR_[A-Z0-9_]+/;
const SCOPE = "https://www.googleapis.com/auth/cloud-platform";

function vertexFromEnv(): LlmGateway {
  const raw = Deno.env.get("VERTEX_SERVICE_ACCOUNT_JSON");
  if (!raw) {
    return { generate: (): Promise<GenerateResult> => Promise.reject(new LlmUnavailable(["not configured"])) };
  }
  const account = parseServiceAccount(raw);
  const tokens = new ServiceAccountTokens(account, SCOPE);
  return new VertexGemini({
    project: Deno.env.get("VERTEX_PROJECT") || account.project_id,
    accessToken: (signal) => tokens.get(signal),
  });
}

const llm = vertexFromEnv();

export default {
  fetch: instrument(
    "concierge",
    withSupabase({ auth: "user" }, (req, ctx) =>
      createConciergeHandler({
        async rpc(fn, args) {
          const { data, error } = await ctx.supabase.rpc(fn, args);
          if (error) {
            const code = error.message?.match(WIRE_CODE)?.[0];
            if (code) throw new RpcError(code);
            throw new Error(error.message);
          }
          return data;
        },
        llm,
        log,
      })(req)),
    { reporter: sentryReporterFromEnv() },
  ),
};
