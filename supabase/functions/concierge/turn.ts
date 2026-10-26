// The turn schema (ai-design §5.3) and the validator that stands between a model and the state.
//
// The validator decides, not the model: unknown slot keys are dropped, money keys are refused
// outright, a category must be one the database listed, and `proposed_action` is only what this
// version can honour. `show_publish_card` and `show_offer_comparison` need a request on the server,
// and in v1 every errand is posted through the form, where the map pin and the price are set.

export const URGENCIES = ["flexible", "standard", "urgent", "emergency"] as const;
export const FLAGS = ["distress", "restricted_item", "off_platform_payment", "abuse"] as const;
export const ACTIONS = ["none", "handoff_to_form", "show_sos_card"] as const;
export const SLOT_KEYS = [
  "category_key",
  "custom_category_label",
  "description",
  "pickup_label",
  "pickup_landmark_note",
  "destination_label",
  "destination_landmark_note",
  "urgency",
  "scheduled_at",
] as const;
const SLOT_HELP: Record<typeof SLOT_KEYS[number], string> = {
  category_key: "One of the listed category keys.",
  custom_category_label: "Only with category_key custom: a few words for the service.",
  description: "One sentence: what needs doing.",
  pickup_label: "Where the errand starts, as the customer said it (an area, street or landmark).",
  pickup_landmark_note: "Extra detail to find the pickup: a gate, a floor, a nearby landmark.",
  destination_label: "Where it ends, for anything taken somewhere: 'to Ikeja GRA' gives 'Ikeja GRA'.",
  destination_landmark_note: "Extra detail to find the destination.",
  urgency: "Only if the customer said how soon: flexible, standard, urgent or emergency.",
  scheduled_at: "Only if they gave a date and time, ISO 8601.",
};

export const REQUIRED_SLOTS = ["category_key", "description", "pickup_label"] as const;
const MONEY = /price|amount|float|value|budget|minor|cost|fee/i;

export type Action = typeof ACTIONS[number];
export type Flag = typeof FLAGS[number];
export type Slots = Partial<Record<typeof SLOT_KEYS[number], string>>;

export interface Turn {
  reply: string;
  language: "en" | "pcm";
  slotUpdates: Slots;
  proposedAction: Action;
  safetyFlags: Flag[];
}

export interface Category {
  id: string;
  key: string;
  allows_custom?: boolean;
}

// Gemini emits properties alphabetically unless told otherwise, and with the destination before the
// pickup the model wrote "Ikeja GRA" into scheduled_at (evals, 2026-10-26). So the order is stated:
// the slots in the order a person says them. The reply goes first: with the slots first and no
// thinking budget, the model sometimes emitted them empty before it had read the message.
export const RESPONSE_SCHEMA = {
  type: "OBJECT",
  propertyOrdering: ["reply", "language", "slot_updates", "proposed_action", "safety_flags"],
  properties: {
    reply: { type: "STRING" },
    language: { type: "STRING", enum: ["en", "pcm"] },
    slot_updates: {
      type: "OBJECT",
      description:
        "Every detail the customer has given so far that is not already in the errand. Leave out what they did not say.",
      properties: Object.fromEntries(SLOT_KEYS.map((k) => [k, { type: "STRING", description: SLOT_HELP[k] }])),
      propertyOrdering: [...SLOT_KEYS],
    },
    proposed_action: { type: "STRING", enum: [...ACTIONS] },
    safety_flags: { type: "ARRAY", items: { type: "STRING", enum: [...FLAGS] } },
  },
  required: ["reply", "language", "proposed_action"],
};

export type Validation = { ok: true; turn: Turn } | { ok: false; reason: string };

export function validateTurn(raw: unknown, categories: Category[]): Validation {
  if (!raw || typeof raw !== "object") return { ok: false, reason: "not_an_object" };
  const o = raw as Record<string, unknown>;
  const reply = typeof o.reply === "string" ? o.reply.trim() : "";
  if (!reply || reply.length > 600) return { ok: false, reason: "reply_length" };
  if (o.language !== "en" && o.language !== "pcm") return { ok: false, reason: "language" };
  if (!ACTIONS.includes(o.proposed_action as Action)) return { ok: false, reason: "action" };

  const slotUpdates: Slots = {};
  const updates = (o.slot_updates ?? {}) as Record<string, unknown>;
  if (typeof updates !== "object") return { ok: false, reason: "slot_updates" };
  for (const [key, value] of Object.entries(updates)) {
    if (MONEY.test(key)) return { ok: false, reason: `money_field:${key}` };
    if (!(SLOT_KEYS as readonly string[]).includes(key)) continue;
    if (typeof value !== "string" || !value.trim()) continue;
    const v = value.trim().slice(0, 300);
    if (key === "category_key" && v !== "custom" && !categories.some((c) => c.key === v)) {
      return { ok: false, reason: "unknown_category" };
    }
    if (key === "urgency" && !(URGENCIES as readonly string[]).includes(v)) continue;
    if (key === "scheduled_at" && Number.isNaN(Date.parse(v))) continue;
    slotUpdates[key as keyof Slots] = v;
  }
  const flags = Array.isArray(o.safety_flags)
    ? (o.safety_flags as unknown[]).filter((f): f is Flag => FLAGS.includes(f as Flag))
    : [];
  return {
    ok: true,
    turn: { reply, language: o.language, slotUpdates, proposedAction: o.proposed_action as Action, safetyFlags: flags },
  };
}

/** The state after this turn, and what the app's draft card shows. */
export function applySlots(state: Slots, updates: Slots, categories: Category[]) {
  const next: Slots = { ...state, ...updates };
  if (next.category_key !== "custom") delete next.custom_category_label;
  const category = categories.find((c) => c.key === next.category_key);
  const missing = REQUIRED_SLOTS.filter((k) => !next[k]);
  const draft: Record<string, unknown> = {
    ...next,
    category_id: category?.id ?? null,
    is_custom_category: next.category_key === "custom",
    missing_slots: missing,
  };
  return { state: next, draft, missing };
}
