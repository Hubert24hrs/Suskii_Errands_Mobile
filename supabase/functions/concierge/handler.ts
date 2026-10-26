// One concierge turn (ai-design §3): begin → redact → rules → model ⇄ tools → validate → filter
// → record. The model proposes; this code and then the customer decide (§1, rule 1).
//
// Everything that can go wrong ends in a reply, not an error, when it is safe to: the switch off,
// a limit hit, the model down or talking nonsense twice. Each of those hands the customer to the
// form with what was gathered so far (§6.5, §6.6), because the app must never be blocked on the AI.

import { errorResponse, json } from "../_shared/http.ts";
import type { Content, LlmGateway, Part, Route, Usage } from "../_shared/ai/llm.ts";
import { LlmUnavailable } from "../_shared/ai/llm.ts";
import { redact } from "../_shared/ai/redact.ts";
import { filterReply } from "./filter.ts";
import { PROMPT_VERSION, systemPrompt } from "./prompt.ts";
import { limitReply, looksLikeDistress, sosReply, unavailableReply } from "./safety.ts";
import { DECLARATIONS, type Rpc, runTool } from "./tools.ts";
import {
  type Action,
  applySlots,
  type Category,
  type Flag,
  RESPONSE_SCHEMA,
  type Slots,
  validateTurn,
} from "./turn.ts";

export class RpcError extends Error {
  constructor(readonly code: string) {
    super(code);
  }
}

export interface ConciergeDeps {
  rpc: Rpc;
  llm: LlmGateway;
  now?: () => number;
  log(level: "info" | "warn" | "error", event: string, fields?: Record<string, unknown>): void;
}

interface Begin {
  conversation_id: string;
  enabled: boolean;
  limited: string | null;
  replay: Record<string, unknown> | null;
  language: "en" | "pcm";
  currency: { code: string; exponent: number };
  state: Slots;
  history: Array<{ role: "user" | "assistant"; body: string }>;
  categories: Category[];
  routes: Route[];
  country_code: string;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_TOOL_ROUNDS = 3;
const STATUS_FOR: Record<string, number> = {
  ERR_CONVERSATION_NOT_FOUND: 404,
  ERR_IDEMPOTENCY_KEY_INVALID: 400,
  ERR_IDEMPOTENCY_KEY_REUSED: 409,
  ERR_INVALID_ARGUMENT: 400,
  ERR_UNAUTHENTICATED: 401,
};

export function createConciergeHandler(deps: ConciergeDeps) {
  const now = deps.now ?? Date.now;

  return async (req: Request): Promise<Response> => {
    if (req.method !== "POST") return errorResponse(405, "ERR_METHOD_NOT_ALLOWED");
    let body: { conversation_id?: unknown; text?: unknown; idempotency_key?: unknown };
    try {
      body = await req.json();
    } catch {
      return errorResponse(400, "ERR_INVALID_ARGUMENT");
    }
    const conversationId = typeof body.conversation_id === "string" ? body.conversation_id : "";
    const text = typeof body.text === "string" ? body.text.trim() : "";
    const key = typeof body.idempotency_key === "string" ? body.idempotency_key : "";
    if (!UUID.test(conversationId) || !text || text.length > 1000 || key.length < 16 || key.length > 128) {
      return errorResponse(400, "ERR_INVALID_ARGUMENT");
    }

    const started = now();
    try {
      const begin = await deps.rpc("concierge_begin_turn", {
        p_conversation_id: conversationId,
        p_idempotency_key: key,
      }) as Begin;
      if (begin.replay) return json(answer(begin.replay));

      const userBody = redact(text).text.slice(0, 2000);
      const language = begin.language === "pcm" ? "pcm" : "en";
      let outcome: Outcome;
      if (looksLikeDistress(text)) {
        outcome = fixed(sosReply(language), language, "show_sos_card", ["distress"], "rules");
      } else if (!begin.enabled || !validRoutes(begin.routes).length) {
        outcome = fixed(unavailableReply(language), language, "handoff_to_form", [], "unavailable");
      } else if (begin.limited) {
        outcome = fixed(limitReply(language), language, "handoff_to_form", [], `limited_${begin.limited}`);
      } else {
        outcome = await converse(deps, begin, userBody, language);
      }

      const { state, draft, missing } = applySlots(begin.state ?? {}, outcome.slotUpdates, begin.categories);
      const recorded = await deps.rpc("concierge_record_turn", {
        p_conversation_id: conversationId,
        p_idempotency_key: key,
        p_user_body: userBody,
        p_reply: outcome.reply,
        p_language: outcome.language,
        p_state: state,
        p_draft: draft,
        p_proposed_action: outcome.action,
        p_safety_flags: outcome.flags,
        p_model_id: outcome.model,
        p_prompt_version: outcome.model ? PROMPT_VERSION : null,
        p_tokens_in: outcome.usage.input,
        p_tokens_out: outcome.usage.output,
        p_tokens_thought: outcome.usage.thought,
        p_latency_ms: now() - started,
        p_tool_calls: outcome.toolCalls,
      }) as Record<string, unknown>;

      deps.log("info", "concierge.turn", {
        outcome: outcome.source,
        model: outcome.model,
        location: outcome.location,
        latency_ms: now() - started,
        tokens_in: outcome.usage.input,
        tokens_out: outcome.usage.output,
        tool_calls: outcome.toolCalls.length,
        flags: outcome.flags,
        missing: missing.length,
        action: outcome.action,
      });
      return json(answer(recorded));
    } catch (err) {
      if (err instanceof RpcError) return errorResponse(STATUS_FOR[err.code] ?? 400, err.code);
      deps.log("error", "concierge.failed", { error: err instanceof Error ? err.name : "unknown" });
      return errorResponse(500, "ERR_INTERNAL");
    }
  };
}

function answer(m: Record<string, unknown>) {
  return {
    message: m,
    reply: m.body,
    proposed_action: m.proposed_action,
    draft: m.structured_draft ?? null,
  };
}

interface Outcome {
  reply: string;
  language: "en" | "pcm";
  action: Action;
  flags: Flag[];
  slotUpdates: Slots;
  model: string | null;
  location: string | null;
  usage: Usage;
  toolCalls: Array<{ name: string; ok: boolean }>;
  source: string;
}

function fixed(reply: string, language: "en" | "pcm", action: Action, flags: Flag[], source: string): Outcome {
  return {
    reply,
    language,
    action,
    flags,
    slotUpdates: {},
    model: null,
    location: null,
    usage: { input: 0, output: 0, thought: 0 },
    toolCalls: [],
    source,
  };
}

function validRoutes(routes: unknown): Route[] {
  if (!Array.isArray(routes)) return [];
  return routes.filter((r): r is Route =>
    !!r && typeof r === "object" && typeof (r as Route).model === "string" &&
    typeof (r as Route).location === "string" && /^[a-z0-9-]+$/.test((r as Route).location) &&
    /^[a-z0-9.-]+$/.test((r as Route).model)
  );
}

async function converse(deps: ConciergeDeps, begin: Begin, userBody: string, language: "en" | "pcm"): Promise<Outcome> {
  const routes = validRoutes(begin.routes);
  const system = systemPrompt({
    countryCode: begin.country_code,
    currencyCode: begin.currency.code,
    categories: begin.categories.map((c) => c.key),
  });
  const contents: Content[] = [];
  for (const h of begin.history ?? []) {
    contents.push({ role: h.role === "assistant" ? "model" : "user", parts: [{ text: h.body }] });
  }
  contents.push({
    role: "user",
    parts: [{
      text: `Errand so far: ${JSON.stringify(begin.state ?? {})}\nThe customer's language so far: ${language}\n` +
        `<user_content>${userBody}</user_content>`,
    }],
  });

  const usage: Usage = { input: 0, output: 0, thought: 0 };
  const toolCalls: Array<{ name: string; ok: boolean }> = [];
  const amounts: string[] = [];
  let rejected = 0;
  let amountRetry = false;
  let model: string | null = null;
  let location: string | null = null;

  try {
    for (let round = 0; round < MAX_TOOL_ROUNDS + 3; round++) {
      const result = await deps.llm.generate({
        system,
        contents,
        tools: DECLARATIONS,
        responseSchema: RESPONSE_SCHEMA,
        maxOutputTokens: 600,
        temperature: 0.3,
      }, routes);
      usage.input += result.usage.input;
      usage.output += result.usage.output;
      usage.thought += result.usage.thought;
      model = result.model;
      location = result.location;

      const calls = result.parts.filter((p) => p.functionCall);
      if (calls.length && toolCalls.length < MAX_TOOL_ROUNDS * 2) {
        contents.push({ role: "model", parts: result.parts });
        const responses: Part[] = [];
        for (const p of calls) {
          const call = p.functionCall!;
          const out = await runTool(call.name, call.args ?? {}, {
            rpc: deps.rpc,
            categories: begin.categories,
            currency: begin.currency,
          }).catch(() => ({ response: { error: "tool_failed" }, amounts: [] as string[], ok: false }));
          toolCalls.push({ name: call.name, ok: out.ok });
          amounts.push(...out.amounts);
          responses.push({
            functionResponse: { name: call.name, response: out.response, ...(call.id ? { id: call.id } : {}) },
          });
        }
        contents.push({ role: "user", parts: responses });
        continue;
      }

      const raw = result.parts.map((p) => p.text ?? "").join("");
      let parsed: unknown;
      try {
        parsed = JSON.parse(raw);
      } catch {
        parsed = null;
      }
      const v = validateTurn(parsed, begin.categories);
      if (!v.ok) {
        // ai-design §5.3: two rejections and the customer finishes on the form.
        if (++rejected >= 2) break;
        contents.push({ role: "model", parts: [{ text: raw.slice(0, 2000) || "{}" }] });
        contents.push({
          role: "user",
          parts: [{ text: `That answer was refused (${v.reason}). Answer again with only the JSON object.` }],
        });
        continue;
      }

      const f = filterReply(v.turn.reply, amounts);
      if (f.unknownAmounts.length && !amountRetry) {
        amountRetry = true;
        contents.push({ role: "model", parts: [{ text: raw.slice(0, 2000) }] });
        contents.push({
          role: "user",
          parts: [{
            text:
              "That reply quoted an amount no tool returned. Quote amounts only exactly as estimate_price_band returned them, or none.",
          }],
        });
        continue;
      }
      let reply = f.reply;
      for (const a of f.unknownAmounts) reply = reply.replace(a, "");
      reply = reply.replace(/\s{2,}/g, " ").trim() || unavailableReply(v.turn.language);

      const flags = v.turn.safetyFlags;
      const action: Action = flags.includes("distress") ? "show_sos_card" : v.turn.proposedAction;
      return {
        reply,
        language: v.turn.language,
        action,
        flags,
        slotUpdates: v.turn.slotUpdates,
        model,
        location,
        usage,
        toolCalls,
        source: "model",
      };
    }
  } catch (err) {
    if (!(err instanceof LlmUnavailable)) throw err;
    deps.log("warn", "concierge.llm_unavailable", { attempts: err.attempts });
    return {
      ...fixed(unavailableReply(language), language, "handoff_to_form", [], "llm_unavailable"),
      usage,
      toolCalls,
    };
  }
  return {
    ...fixed(unavailableReply(language), language, "handoff_to_form", [], "schema_rejected"),
    usage,
    toolCalls,
    model,
    location,
  };
}
