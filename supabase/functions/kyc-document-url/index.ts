import "@supabase/functions-js/edge-runtime.d.ts";
import { withSupabase } from "@supabase/server";
import { log } from "../_shared/log.ts";
import { instrument } from "../_shared/observability.ts";
import { sentryReporterFromEnv } from "../_shared/sentry.ts";
import { AccessRefusedError, createDocumentUrlHandler } from "./handler.ts";

const WIRE_CODE = /ERR_[A-Z0-9_]+/;

export default {
  fetch: instrument(
    "kyc-document-url",
    withSupabase({ auth: "user" }, (req, ctx) =>
      createDocumentUrlHandler({
        async requestAccess(uploadRef, reasonCode) {
          // As the officer: the database checks aal2, the role and the folder, and audits.
          const { data, error } = await ctx.supabase.rpc("request_document_access", {
            p_upload_ref: uploadRef,
            p_reason_code: reasonCode,
          });
          if (error) {
            const code = error.message?.match(WIRE_CODE)?.[0];
            if (code) throw new AccessRefusedError(code);
            throw new Error(error.message);
          }
          return String(data);
        },
        async sign(path, ttlSeconds) {
          const { data, error } = await ctx.supabaseAdmin.storage.from("kyc-docs")
            .createSignedUrl(path, ttlSeconds);
          if (error || !data?.signedUrl) throw new Error(error?.message ?? "no signed url");
          return data.signedUrl;
        },
        now: () => Date.now(),
        log,
      })(req)),
    { reporter: sentryReporterFromEnv() },
  ),
};
