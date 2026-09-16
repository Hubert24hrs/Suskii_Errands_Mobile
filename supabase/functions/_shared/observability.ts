// Request instrumentation shared by every Edge Function (infra-cicd.md §7):
//   * a request id, echoed as x-request-id so apps can quote it to support;
//   * one structured completion log line with status and duration;
//   * uncaught errors reported to the error tracker and turned into a safe 500.
// Nothing from the request body, headers or user identity is attached to logs or reports
// (data-flow rule 3): tokens, OTPs and phone numbers travel in exactly those places.

import { log } from "./log.ts";

export interface ErrorContext {
  functionName: string;
  requestId: string;
  tags?: Record<string, string>;
}

export interface ErrorReporter {
  capture(error: unknown, context: ErrorContext): void;
  flush(timeoutMs: number): Promise<void>;
}

export const noopReporter: ErrorReporter = {
  capture: () => {},
  flush: () => Promise.resolve(),
};

export type Handler = (req: Request) => Promise<Response>;

export interface InstrumentOptions {
  reporter?: ErrorReporter;
  /** Builds the error response; Auth hooks need their own body shape. */
  onUnhandledError?: (requestId: string) => Response;
  now?: () => number;
  env?: (key: string) => string | undefined;
}

export function instrument(functionName: string, handler: Handler, options: InstrumentOptions = {}): Handler {
  const reporter = options.reporter ?? noopReporter;
  const now = options.now ?? (() => performance.now());
  const env = options.env ?? ((key: string) => Deno.env.get(key));

  return async (req: Request): Promise<Response> => {
    const requestId = crypto.randomUUID();
    const started = now();
    let response: Response;
    try {
      response = await handler(req);
    } catch (error) {
      reporter.capture(error, { functionName, requestId, tags: { region: env("SB_REGION") ?? "unknown" } });
      log("error", "request.unhandled_error", {
        function: functionName,
        request_id: requestId,
        error_name: error instanceof Error ? error.name : typeof error,
      });
      // Flush before returning: the runtime may be torn down right after the response.
      await reporter.flush(2_000);
      response = options.onUnhandledError?.(requestId) ??
        new Response(JSON.stringify({ error: { code: "ERR_INTERNAL", request_id: requestId } }), {
          status: 500,
          headers: { "content-type": "application/json" },
        });
    }

    const headers = new Headers(response.headers);
    headers.set("x-request-id", requestId);
    log("info", "request.completed", {
      function: functionName,
      request_id: requestId,
      method: req.method,
      status: response.status,
      duration_ms: Math.round(now() - started),
      region: env("SB_REGION"),
      execution_id: env("SB_EXECUTION_ID"),
    });
    return new Response(response.body, { status: response.status, statusText: response.statusText, headers });
  };
}
