// Rules that run before and after the model, and that it cannot overrule (ai-design §6.4).
//
// Distress is rules first: a phrase list in English and Pidgin, matched on the raw message before
// redaction. Either this or the model's flag shows the SOS card. False positives are acceptable
// here and misses are not, so the list is broad on purpose and the response is an offer of help,
// never an accusation.

const DISTRESS = [
  /\b(help me|save me|i('| a)?m in danger|in danger|i('| a)?m scared|i am scared|being followed|following me)\b/i,
  /\b(kidnap\w*|abduct\w*|rap(e|ed|ing)|assault\w*|attack(ed|ing)?|stab(bed)?|shot|gun|bleeding|robb(ed|ery|ers?))\b/i,
  /\b(he|she|they|someone|somebody|man|driver|rider) (is |are )?(hitting|beating|touching|threatening)\b/i,
  /\b(dem|e|im|una) (wan|dey) (kill|kidnap|beat|attack) me\b/i,
  /\b(e don happen to me|dem don hold me|i no fit comot|abeg help|help o+|somebody dey follow me|dey follow me)\b/i,
  /\b(call (the )?police|police!|emergency)\b/i,
];

export function looksLikeDistress(text: string): boolean {
  return DISTRESS.some((rule) => rule.test(text));
}

export function sosReply(language: "en" | "pcm"): string {
  return language === "pcm"
    ? "Your safety first. Press the SOS button for here now, or call the emergency number wey dey below. I don stop the errand."
    : "Your safety comes first. Press SOS here now, or call the emergency number below. I have paused the errand.";
}

export function unavailableReply(language: "en" | "pcm"): string {
  return language === "pcm"
    ? "Ask Suskii no dey available now. You fit still post your errand: tap “Use the form”."
    : "Ask Suskii isn't available right now. You can still post your errand: tap “Use the form”.";
}

export function limitReply(language: "en" | "pcm"): string {
  return language === "pcm"
    ? "We don reach the limit for now. Wetin we don get go dey for the form: tap “Use the form” to finish am."
    : "We've reached the limit for now. What we have so far is on the form: tap “Use the form” to finish.";
}
