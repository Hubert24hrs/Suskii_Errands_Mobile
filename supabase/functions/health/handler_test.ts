import { assertEquals } from "@std/assert";
import { createHealthHandler, type HealthSnapshot, type SafetyAlarm } from "./handler.ts";

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

const alarm = (status: SafetyAlarm["status"], unacknowledged = 0): SafetyAlarm => ({
  status,
  checked_at: "2026-10-26T03:00:00Z",
  unacknowledged,
  oldest_escalated_seconds: unacknowledged ? 75 : null,
});
const safety = () => new Request("http://localhost/health?scope=safety");

Deno.test("the safety scope returns 503 while an escalated SOS is unacknowledged", async () => {
  const res = await createHealthHandler({
    getHealth: () => Promise.reject(new Error("the default scope must not be read")),
    getSafetyAlarm: () => Promise.resolve(alarm("fail", 1)),
  })(safety());
  assertEquals(res.status, 503);
  assertEquals((await res.json()).unacknowledged, 1);
  assertEquals(res.headers.get("cache-control"), "no-store");
});

Deno.test("the safety scope is 200 with nobody waiting, whatever the platform's health", async () => {
  const res = await createHealthHandler({
    getHealth: () => Promise.resolve(snapshot("fail")),
    getSafetyAlarm: () => Promise.resolve(alarm("ok")),
  })(safety());
  assertEquals(res.status, 200);
});

Deno.test("a safety check that cannot reach the database pages rather than guessing", async () => {
  const res = await createHealthHandler({
    getHealth: () => Promise.resolve(snapshot("ok")),
    getSafetyAlarm: () => Promise.reject(new Error("connection refused")),
  })(safety());
  assertEquals(res.status, 503);
  assertEquals(JSON.stringify(await res.json()).includes("connection refused"), false);
});

Deno.test("an SOS never fails the default scope, which the deploy smoke test reads", async () => {
  const res = await createHealthHandler({
    getHealth: () => Promise.resolve(snapshot("ok")),
    getSafetyAlarm: () => Promise.resolve(alarm("fail", 2)),
  })(get());
  assertEquals(res.status, 200);
});

Deno.test("an unknown scope is refused rather than read as the default", async () => {
  const res = await createHealthHandler({ getHealth: () => Promise.resolve(snapshot("ok")) })(
    new Request("http://localhost/health?scope=everything"),
  );
  assertEquals(res.status, 400);
});
