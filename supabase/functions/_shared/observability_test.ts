import { assertEquals, assertExists } from "@std/assert";
import { type ErrorContext, type ErrorReporter, instrument } from "./observability.ts";

console.log = () => {};
console.error = () => {};

class RecordingReporter implements ErrorReporter {
  captured: { error: unknown; context: ErrorContext }[] = [];
  flushed = 0;
  capture(error: unknown, context: ErrorContext) {
    this.captured.push({ error, context });
  }
  flush() {
    this.flushed++;
    return Promise.resolve();
  }
}

const env = () => undefined;

Deno.test("successful responses pass through with a request id", async () => {
  const handler = instrument("fn", () => Promise.resolve(new Response("hi", { status: 201 })), { env });
  const res = await handler(new Request("http://localhost"));
  assertEquals(res.status, 201);
  assertEquals(await res.text(), "hi");
  assertExists(res.headers.get("x-request-id"));
});

Deno.test("an uncaught error is reported, flushed and turned into a safe 500", async () => {
  const reporter = new RecordingReporter();
  const handler = instrument("fn", () => Promise.reject(new Error("boom: +2348012345678")), { reporter, env });
  const res = await handler(new Request("http://localhost", { method: "POST", body: "secret-otp=123456" }));
  assertEquals(res.status, 500);
  const body = await res.json();
  assertEquals(body.error.code, "ERR_INTERNAL");
  assertEquals(body.error.request_id, res.headers.get("x-request-id"));
  assertEquals(JSON.stringify(body).includes("boom"), false);
  assertEquals(reporter.captured.length, 1);
  assertEquals(reporter.captured[0].context.functionName, "fn");
  assertEquals(reporter.flushed, 1);
});

Deno.test("hooks can supply their own error body", async () => {
  const handler = instrument("hook", () => Promise.reject(new Error("x")), {
    env,
    onUnhandledError: () =>
      new Response(JSON.stringify({ error: { http_code: 500, message: "ERR_INTERNAL" } }), {
        status: 500,
        headers: { "content-type": "application/json" },
      }),
  });
  const res = await handler(new Request("http://localhost"));
  assertEquals((await res.json()).error.http_code, 500);
  assertEquals(res.headers.get("content-type"), "application/json");
});

Deno.test("the completion log carries no request content", async () => {
  const lines: string[] = [];
  console.log = (line: string) => lines.push(line);
  const handler = instrument("fn", () => Promise.resolve(new Response("ok")), { env });
  await handler(new Request("http://localhost/x?phone=2348012345678", { headers: { authorization: "Bearer t" } }));
  console.log = () => {};
  const logged = lines.join("\n");
  assertEquals(logged.includes("request.completed"), true);
  assertEquals(logged.includes("2348012345678"), false);
  assertEquals(logged.includes("Bearer"), false);
});
