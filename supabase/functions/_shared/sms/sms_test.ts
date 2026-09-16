import { assertEquals } from "@std/assert";
import { sendWithFailover } from "./failover.ts";
import { isValidOtp, otpMessage } from "./message.ts";
import { ConsoleSmsProvider, type SmsProvider, type SmsSendResult } from "./provider.ts";
import { CachedRouteSource, routeFor, routesFromRows } from "./routing.ts";

const ROWS = [
  { code: "NG", calling_code: "234", config: { server: { sms_providers: ["primary", "backup"] } } },
  { code: "ZA", calling_code: "27", config: { server: {} } },
  { code: "XX", calling_code: "2", config: null },
];

class FakeProvider implements SmsProvider {
  calls = 0;
  constructor(readonly name: string, private readonly behaviour: "ok" | "fail" | "throw" | "hang") {}
  send(_to: string, _msg: string, _signal: AbortSignal): Promise<SmsSendResult> {
    this.calls++;
    switch (this.behaviour) {
      case "ok":
        return Promise.resolve({ ok: true, messageId: `${this.name}-1` });
      case "fail":
        return Promise.resolve({ ok: false, reason: "vendor_rejected" });
      case "throw":
        return Promise.reject(new Error("network"));
      case "hang":
        return new Promise(() => {}); // ignores the abort signal on purpose
    }
  }
}

Deno.test("routing picks the longest matching calling code", () => {
  const routes = routesFromRows(ROWS);
  assertEquals(routeFor("2348012345678", routes)?.countryCode, "NG");
  assertEquals(routeFor("27821234567", routes)?.countryCode, "ZA");
  assertEquals(routeFor("14155550100", routes), null);
});

Deno.test("routing reads the ordered provider list and tolerates missing config", () => {
  const routes = routesFromRows(ROWS);
  assertEquals(routes[0].providers, ["primary", "backup"]);
  assertEquals(routes[1].providers, []);
  assertEquals(routes[2].providers, []);
});

Deno.test("routes are cached for the TTL", async () => {
  let fetches = 0;
  let clock = 0;
  const source = new CachedRouteSource(
    () => {
      fetches++;
      return Promise.resolve(ROWS);
    },
    60_000,
    () => clock,
  );
  await source.load();
  clock = 59_999;
  await source.load();
  assertEquals(fetches, 1);
  clock = 60_001;
  await source.load();
  assertEquals(fetches, 2);
});

Deno.test("failover moves to the next provider on rejection and on exceptions", async () => {
  const a = new FakeProvider("a", "fail");
  const b = new FakeProvider("b", "throw");
  const c = new FakeProvider("c", "ok");
  const result = await sendWithFailover(["a", "b", "c"], new Map([["a", a], ["b", b], ["c", c]]), "234", "m", {
    deadlineMs: 4_000,
  });
  assertEquals(result.ok, true);
  assertEquals(result.provider, "c");
  assertEquals(result.attempts.map((x) => [x.provider, x.ok, x.reason]), [
    ["a", false, "vendor_rejected"],
    ["b", false, "exception"],
    ["c", true, undefined],
  ]);
});

Deno.test("failover stops at the first success", async () => {
  const a = new FakeProvider("a", "ok");
  const b = new FakeProvider("b", "ok");
  await sendWithFailover(["a", "b"], new Map([["a", a], ["b", b]]), "234", "m", { deadlineMs: 4_000 });
  assertEquals([a.calls, b.calls], [1, 0]);
});

Deno.test("a provider that ignores its abort signal cannot exceed the deadline", async () => {
  const hang = new FakeProvider("hang", "hang");
  const started = Date.now();
  const result = await sendWithFailover(["hang"], new Map([["hang", hang]]), "234", "m", {
    deadlineMs: 150,
    minAttemptMs: 50,
  });
  assertEquals(result.ok, false);
  assertEquals(result.attempts[0].reason, "timeout");
  assertEquals(Date.now() - started < 1_000, true);
});

Deno.test("unregistered providers are recorded and skipped", async () => {
  const ok = new FakeProvider("ok", "ok");
  const result = await sendWithFailover(["missing", "ok"], new Map([["ok", ok]]), "234", "m", { deadlineMs: 4_000 });
  assertEquals(result.attempts[0].reason, "provider_not_registered");
  assertEquals(result.provider, "ok");
});

Deno.test("the console provider refuses to run in production", async () => {
  const signal = AbortSignal.timeout(1_000);
  assertEquals((await new ConsoleSmsProvider("production").send("234", "m", signal)).ok, false);
  assertEquals((await new ConsoleSmsProvider("development").send("234", "m", signal)).ok, true);
});

Deno.test("OTP message carries the code and the Android retriever hash on its own line", () => {
  assertEquals(otpMessage("123456").includes("123456"), true);
  assertEquals(otpMessage("123456", "FA+9qCX9VSu").endsWith("\nFA+9qCX9VSu"), true);
  // SMS Retriever messages must stay within a single 140-byte SMS.
  assertEquals(new TextEncoder().encode(otpMessage("123456", "FA+9qCX9VSu")).length <= 140, true);
});

Deno.test("OTP validation accepts exactly six digits", () => {
  assertEquals(isValidOtp("123456"), true);
  assertEquals(isValidOtp("12345"), false);
  assertEquals(isValidOtp("12345a"), false);
  assertEquals(isValidOtp(123456), false);
});
