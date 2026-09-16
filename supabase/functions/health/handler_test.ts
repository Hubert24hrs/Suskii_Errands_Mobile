import { assertEquals } from "@std/assert";
import { createHealthHandler, type HealthSnapshot } from "./handler.ts";

const snapshot = (status: HealthSnapshot["status"]): HealthSnapshot => ({
  status,
  checked_at: "2026-09-16T12:00:00Z",
  checks: { audit_chain: { status } },
});

const get = () => new Request("http://localhost/health");

Deno.test("healthy and warning states return 200 with the checks", async () => {
  for (const status of ["ok", "warn"] as const) {
    const res = await createHealthHandler({ getHealth: () => Promise.resolve(snapshot(status)) })(get());
    assertEquals(res.status, 200);
    assertEquals((await res.json()).status, status);
    assertEquals(res.headers.get("cache-control"), "no-store");
  }
});

Deno.test("a failing check returns 503 so uptime checks alert", async () => {
  const res = await createHealthHandler({ getHealth: () => Promise.resolve(snapshot("fail")) })(get());
  assertEquals(res.status, 503);
});

Deno.test("an unreachable database returns 503", async () => {
  const res = await createHealthHandler({ getHealth: () => Promise.reject(new Error("connection refused")) })(get());
  assertEquals(res.status, 503);
  const body = await res.json();
  assertEquals(body.checks.database.reason, "unreachable");
  assertEquals(JSON.stringify(body).includes("connection refused"), false);
});

Deno.test("reports database latency and release", async () => {
  let t = 0;
  const res = await createHealthHandler({
    getHealth: () => {
      t = 42;
      return Promise.resolve(snapshot("ok"));
    },
    release: "abc123",
    now: () => t,
  })(get());
  const body = await res.json();
  assertEquals([body.db_latency_ms, body.release], [42, "abc123"]);
});

Deno.test("only GET is allowed", async () => {
  const res = await createHealthHandler({ getHealth: () => Promise.resolve(snapshot("ok")) })(
    new Request("http://localhost/health", { method: "POST" }),
  );
  assertEquals(res.status, 405);
});
