// Prints the model's raw JSON for one message, through any tool rounds, before the validator sees
// it. A debugging aid for the evals:
//   VERTEX_ACCESS_TOKEN=... deno run --allow-net --allow-env --allow-read raw_probe.ts <project> "<text>"
import { type Content, type Part, VertexGemini } from "../../_shared/ai/llm.ts";
import { systemPrompt } from "../prompt.ts";
import { RESPONSE_SCHEMA } from "../turn.ts";
import { DECLARATIONS } from "../tools.ts";

const [project, text] = Deno.args;
const migration = await Deno.readTextFile(new URL("../../../migrations/20261026190000_concierge.sql", import.meta.url));
const routes = JSON.parse(migration.match(/'ai\.routes\.concierge\.text', NULL,\s*'(\[[\s\S]*?\])'/)![1]);
const llm = new VertexGemini({ project, accessToken: () => Promise.resolve(Deno.env.get("VERTEX_ACCESS_TOKEN")!) });
const system = systemPrompt({
  countryCode: "NG",
  currencyCode: "NGN",
  categories: ["document_delivery", "errands_delivery", "custom"],
});
const contents: Content[] = [{
  role: "user",
  parts: [{ text: `Errand so far: {}\nThe customer's language so far: en\n<user_content>${text}</user_content>` }],
}];
const ask = async () =>
  (await llm.generate({
    system,
    contents,
    tools: DECLARATIONS,
    responseSchema: RESPONSE_SCHEMA,
    maxOutputTokens: 600,
    temperature: 0.3,
  }, routes)).parts;

let parts: Part[] = await ask();
for (let i = 0; i < 3 && parts.some((p) => p.functionCall); i++) {
  contents.push({ role: "model", parts });
  contents.push({
    role: "user",
    parts: parts.filter((p) => p.functionCall).map((p) => ({
      functionResponse: {
        name: p.functionCall!.name,
        response: { requires_vehicle: false, item_budget_allowed: false, proof: [] },
        ...(p.functionCall!.id ? { id: p.functionCall!.id } : {}),
      },
    })),
  });
  parts = await ask();
}
console.log(parts.map((p) => p.text ?? JSON.stringify(p.functionCall)).join("\n"));
