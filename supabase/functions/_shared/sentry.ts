// Sentry adapter for ErrorReporter. Follows Supabase's Edge Functions guidance: default
// integrations off, and per-event scope instead of global state, because the Deno SDK does
// not isolate requests that share a runtime.

import * as Sentry from "@sentry/deno";
import { type ErrorReporter, noopReporter } from "./observability.ts";

export function sentryReporterFromEnv(
  env: (key: string) => string | undefined = (k) => Deno.env.get(k),
): ErrorReporter {
  const dsn = env("SENTRY_DSN");
  if (!dsn) return noopReporter;

  Sentry.init({
    dsn,
    environment: env("SUSKII_ENV") ?? "development",
    release: env("SUSKII_RELEASE"),
    defaultIntegrations: false,
    tracesSampleRate: 0,
    sendDefaultPii: false,
    // Scrubbing is enforced here, not trusted to call sites: no request, user or breadcrumbs
    // ever leave the function.
    beforeSend(event) {
      delete event.request;
      delete event.user;
      delete event.breadcrumbs;
      delete event.extra;
      return event;
    },
  });

  return {
    capture(error, context) {
      Sentry.withScope((scope) => {
        scope.setTag("function", context.functionName);
        scope.setTag("request_id", context.requestId);
        for (const [key, value] of Object.entries(context.tags ?? {})) scope.setTag(key, value);
        Sentry.captureException(error);
      });
    },
    async flush(timeoutMs) {
      await Sentry.flush(timeoutMs);
    },
  };
}
