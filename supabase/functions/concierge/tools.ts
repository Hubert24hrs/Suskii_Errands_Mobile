// The concierge's tools (ai-design §4.1): each a thin wrapper over a function the app already
// calls, run as the customer through their own JWT, so RLS applies unchanged (ADR-0012). The
// functions are on `services/ai/tools/allowlist.json`; check_allowlist.py fails CI if one is
// renamed. Results go to the model already formatted, and money only as display strings.

import type { FunctionDeclaration } from "../_shared/ai/llm.ts";
import { formatMinor } from "../_shared/ai/money.ts";
import type { Category } from "./turn.ts";

export interface Rpc {
  (fn: string, args: Record<string, unknown>): Promise<unknown>;
}

export const DECLARATIONS: FunctionDeclaration[] = [
  {
    name: "estimate_price_band",
    description:
      "Advisory price range for a category: what similar errands usually cost. A guide, never the price. Quote the amounts exactly as returned.",
    parameters: {
      type: "OBJECT",
      properties: {
        category_key: { type: "STRING" },
        urgency: { type: "STRING", enum: ["flexible", "standard", "urgent", "emergency"] },
      },
      required: ["category_key"],
    },
  },
  {
    name: "get_required_details",
    description:
      "What a category needs: whether a vehicle is required, whether an item budget is allowed, what proof the provider gives.",
    parameters: {
      type: "OBJECT",
      properties: { category_key: { type: "STRING" } },
      required: ["category_key"],
    },
  },
];

export interface ToolContext {
  rpc: Rpc;
  categories: Category[];
  currency: { code: string; exponent: number };
}

export interface ToolOutcome {
  response: Record<string, unknown>;
  /** Display strings the reply may quote; the output filter allows only these. */
  amounts: string[];
  ok: boolean;
}

export async function runTool(name: string, args: Record<string, unknown>, ctx: ToolContext): Promise<ToolOutcome> {
  const category = ctx.categories.find((c) => c.key === args.category_key);
  if (!category) return { response: { error: "unknown_category" }, amounts: [], ok: false };

  if (name === "estimate_price_band") {
    const urgency = typeof args.urgency === "string" ? args.urgency : "standard";
    const rows = await ctx.rpc("get_price_band", { p_category_id: category.id, p_urgency: urgency }) as Array<
      { p25_minor: number; p50_minor: number; p75_minor: number; currency: string; sample_size: number; basis: string }
    >;
    const band = rows?.[0];
    // No band is an honest answer (Phase 7): say so rather than make one up.
    if (!band) return { response: { available: false }, amounts: [], ok: true };
    const exponent = band.currency === ctx.currency.code ? ctx.currency.exponent : 2;
    const low = formatMinor(band.p25_minor, band.currency, exponent);
    const typical = formatMinor(band.p50_minor, band.currency, exponent);
    const high = formatMinor(band.p75_minor, band.currency, exponent);
    return {
      response: {
        available: true,
        low,
        typical,
        high,
        basis: band.basis === "history" ? "recent jobs like this" : "a rough guide, not enough jobs yet",
        sample_size: band.sample_size,
      },
      amounts: [low, typical, high],
      ok: true,
    };
  }

  if (name === "get_required_details") {
    const rows = await ctx.rpc("get_category_requirements", { p_category_id: category.id }) as Array<
      {
        requires_vehicle: boolean;
        allows_custom: boolean;
        proof_requirements: Record<string, unknown>;
        allows_item_float: boolean;
      }
    >;
    const r = rows?.[0];
    if (!r) return { response: { error: "unknown_category" }, amounts: [], ok: false };
    return {
      response: {
        requires_vehicle: r.requires_vehicle,
        item_budget_allowed: r.allows_item_float,
        proof: Object.keys(r.proof_requirements ?? {}),
      },
      amounts: [],
      ok: true,
    };
  }

  return { response: { error: "unknown_tool" }, amounts: [], ok: false };
}
