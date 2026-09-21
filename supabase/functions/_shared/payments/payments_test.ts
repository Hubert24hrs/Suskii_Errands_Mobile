import { assertEquals } from "@std/assert";
import { ConsolePaymentProvider, hmacSha256Hex, timingSafeEqual } from "./provider.ts";
import { providersFor, routeFor, routesFromRows } from "./routing.ts";

const CHECKOUT = {
  paymentId: "11111111-1111-4111-8111-111111111111",
  amountMinor: 500000,
  currency: "NGN",
  countryCode: "NG",
  reference: "ref-1",
  customerRef: "cust-1",
};

Deno.test("console provider refuses to run in production", async () => {
  const p = new ConsolePaymentProvider("production");
  assertEquals((await p.createCheckout(CHECKOUT)).ok, false);
  assertEquals(
    (await p.createTransfer({
      payoutId: "p1",
      amountMinor: 1,
      currency: "NGN",
      countryCode: "NG",
      rail: "bank",
      institutionCode: "058",
      accountNumber: "0123456789",
      holderName: "A",
      reference: "r",
    })).ok,
    false,
  );
  assertEquals((await p.verifyCharge("x")).ok, false);
  // A country pack still routing to `console` in production must fail loudly, not quietly say a
  // customer paid when nobody did.
  const verification = await p.verifyWebhook("{}", new Headers());
  assertEquals(verification.valid, false);
});

Deno.test("console checkout returns a reference and a URL nothing should open", async () => {
  const result = await new ConsolePaymentProvider("development").createCheckout(CHECKOUT);
  assertEquals(result.ok, true);
  assertEquals(result.gatewayReference, `console-${CHECKOUT.paymentId}`);
  assertEquals(result.checkoutUrl?.startsWith("https://checkout.invalid/"), true);
});

Deno.test("console transfer starts pending, because a transfer resolves later", async () => {
  const result = await new ConsolePaymentProvider("development").createTransfer({
    payoutId: "p1",
    amountMinor: 8460,
    currency: "NGN",
    countryCode: "NG",
    rail: "bank",
    institutionCode: "058",
    accountNumber: "0123456789",
    holderName: "A PROVIDER",
    reference: "payout-1",
  });
  assertEquals(result.ok, true);
  assertEquals(result.status, "pending");
});

Deno.test("account resolution has a failure path", async () => {
  const p = new ConsolePaymentProvider("development");
  assertEquals(
    (await p.resolveAccount({
      countryCode: "NG",
      rail: "bank",
      institutionCode: "058",
      accountNumber: "0123456789",
    })).holderName,
    "CONSOLE ACCOUNT",
  );
  assertEquals(
    (await p.resolveAccount({
      countryCode: "NG",
      rail: "bank",
      institutionCode: "058",
      accountNumber: "0123456780",
    })).ok,
    false,
  );
});

Deno.test("a webhook is verified against the raw body, and a tampered one is refused", async () => {
  const p = new ConsolePaymentProvider("development", "s3cret");
  const body = JSON.stringify({
    event_id: "evt-1",
    kind: "charge.succeeded",
    reference: "console-1",
    amount_minor: 500000,
    fee_minor: 14500,
  });
  const headers = new Headers({ "x-console-signature": await hmacSha256Hex("s3cret", body) });

  const ok = await p.verifyWebhook(body, headers);
  assertEquals(ok.valid, true);
  assertEquals(ok.eventId, "evt-1");
  assertEquals(ok.kind, "charge.succeeded");
  assertEquals(ok.amountMinor, 500000);

  // One byte different, same signature: the body is what is signed, not what is parsed.
  const tampered = body.replace("500000", "500001");
  assertEquals((await p.verifyWebhook(tampered, headers)).valid, false);
});

Deno.test("an unknown event kind normalises rather than leaking vendor vocabulary", async () => {
  const p = new ConsolePaymentProvider("development", "s");
  const body = JSON.stringify({ event_id: "e", kind: "some.vendor.thing" });
  const headers = new Headers({ "x-console-signature": await hmacSha256Hex("s", body) });
  assertEquals((await p.verifyWebhook(body, headers)).kind, "other");
});

Deno.test("timing-safe compare rejects different lengths and different content", () => {
  assertEquals(timingSafeEqual("abc", "abc"), true);
  assertEquals(timingSafeEqual("abc", "abcd"), false);
  assertEquals(timingSafeEqual("abc", "abd"), false);
});

const ROWS = [{
  code: "NG",
  config: {
    server: {
      payment_providers: ["flutterwave", "paystack"],
      payment_providers_by_method: { card: ["paystack", "flutterwave"], mobile_money: [] },
      payment_amount_bands: [{ from_minor: 10000000, providers: ["flutterwave"] }],
      payout_providers: ["flutterwave"],
    },
  },
}, { code: "KE", config: null }];

Deno.test("routes come from the country pack, and a country without one is empty", () => {
  const routes = routesFromRows(ROWS);
  assertEquals(routeFor("NG", routes)?.providers, ["flutterwave", "paystack"]);
  assertEquals(routeFor("KE", routes)?.providers, []);
  assertEquals(routeFor("ZA", routes), null);
  // An empty list for a method is dropped rather than shadowing the country default.
  assertEquals(routeFor("NG", routes)?.byMethod.mobile_money, undefined);
});

Deno.test("the band beats the method, which beats the country default", () => {
  const route = routeFor("NG", routesFromRows(ROWS))!;
  // Small card payment: the method wins, and the default still follows as fallback.
  assertEquals(providersFor(route, { method: "card", amountMinor: 500000 }), [
    "paystack",
    "flutterwave",
  ]);
  // Above the band, the cheaper rail changes and the band leads.
  assertEquals(providersFor(route, { method: "card", amountMinor: 20000000 }), [
    "flutterwave",
    "paystack",
  ]);
  assertEquals(providersFor(route, {}), ["flutterwave", "paystack"]);
});
