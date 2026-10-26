import { assertEquals, assertRejects } from "@std/assert";
import { LlmUnavailable, VertexGemini } from "./llm.ts";
import { amountDigits, formatMinor } from "./money.ts";
import { classify, redact } from "./redact.ts";

Deno.test("redaction catches the formats people type", () => {
  const r = redact(
    "Call 0803 123 4567 or +234 803 123 4567, mail a.b@x.ng, NIN 12345678901, acct 0123456789, card 4111 1111 1111 1111",
  );
  assertEquals(
    r.text,
    "Call <PHONE_1> or <PHONE_2>, mail <EMAIL_1>, NIN <GOV_ID_1>, acct <ACCOUNT_1>, card <CARD_1>",
  );
});

Deno.test("short numbers and prices stay: they are the errand", () => {
  assertEquals(redact("2 bags of rice, gate 14, 5000 naira").text, "2 bags of rice, gate 14, 5000 naira");
  assertEquals(classify("12345678"), null);
  assertEquals(classify("123456789"), "NUMBER");
});

Deno.test("money is formatted from minor units with the currency's exponent", () => {
  assertEquals(formatMinor(350000, "NGN", 2), "₦3,500");
  assertEquals(formatMinor("350050", "NGN", 2), "₦3,500.50");
  assertEquals(formatMinor(50000, "UGX", 0), "USh 50,000");
  assertEquals(amountDigits("₦3,500"), amountDigits("NGN 3500"));
});

Deno.test("vertex: a retryable failure is retried, then the next route is tried", async () => {
  const seen: string[] = [];
  const responses = [503, 503, 200];
  const vertex = new VertexGemini({
    project: "p",
    accessToken: () => Promise.resolve("t"),
    sleep: () => Promise.resolve(),
    fetch: (url) => {
      seen.push(String(url));
      const status = responses.shift()!;
      return Promise.resolve(
        status === 200
          ? Response.json({
            candidates: [{ content: { parts: [{ text: "{}" }] }, finishReason: "STOP" }],
            modelVersion: "m2",
          })
          : new Response("busy", { status }),
      );
    },
  });
  const result = await vertex.generate(
    { system: "s", contents: [], maxOutputTokens: 10, temperature: 0 },
    [{ model: "m1", location: "europe-west2" }, { model: "m2", location: "global" }],
  );
  assertEquals(result.model, "m2");
  assertEquals(seen.length, 3);
  assertEquals(
    seen[0].startsWith("https://europe-west2-aiplatform.googleapis.com/v1/projects/p/locations/europe-west2/"),
    true,
  );
  assertEquals(seen[2].startsWith("https://aiplatform.googleapis.com/v1/projects/p/locations/global/"), true);
});

Deno.test("vertex: a 404 is not retried, and no route left is LlmUnavailable", async () => {
  let n = 0;
  const vertex = new VertexGemini({
    project: "p",
    accessToken: () => Promise.resolve("t"),
    sleep: () => Promise.resolve(),
    fetch: () => {
      n++;
      return Promise.resolve(new Response("no", { status: 404 }));
    },
  });
  await assertRejects(
    () =>
      vertex.generate({ system: "s", contents: [], maxOutputTokens: 10, temperature: 0 }, [{
        model: "m",
        location: "global",
      }]),
    LlmUnavailable,
  );
  assertEquals(n, 1);
});

Deno.test("vertex: thinking budget and schema go where Vertex reads them", async () => {
  let sent: {
    systemInstruction?: { parts: Array<{ text: string }> };
    generationConfig?: Record<string, unknown>;
    tools?: Array<{ functionDeclarations: Array<{ name: string }> }>;
  } = {};
  const vertex = new VertexGemini({
    project: "p",
    accessToken: () => Promise.resolve("t"),
    fetch: (_url, init) => {
      sent = JSON.parse(String(init?.body));
      return Promise.resolve(Response.json({ candidates: [{ content: { parts: [] } }] }));
    },
  });
  await vertex.generate(
    {
      system: "rules",
      contents: [],
      tools: [{ name: "t", description: "d", parameters: {} }],
      responseSchema: { type: "OBJECT" },
      maxOutputTokens: 600,
      temperature: 0.3,
    },
    [{ model: "m", location: "europe-west2", thinking_budget: 0 }],
  );
  assertEquals(sent.systemInstruction?.parts[0].text, "rules");
  assertEquals(sent.generationConfig?.thinkingConfig, { thinkingBudget: 0 });
  assertEquals(sent.generationConfig?.responseMimeType, "application/json");
  assertEquals(sent.tools?.[0].functionDeclarations[0].name, "t");
});
