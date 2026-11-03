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

// Why Ask Suskii is not answering this message, from concierge_begin_turn (20261103120200). Each
// says when it comes back, and every one leaves the form working, so the assistant never looks
// broken when it is only rationed.
export function limitReply(language: "en" | "pcm", reason: string): string {
  const pcm = language === "pcm";
  const form = pcm
    ? " Wetin we don get go dey for the form: tap “Use the form” to finish am."
    : " What we have so far is on the form: tap “Use the form” to finish.";
  switch (reason) {
    case "day":
      return (pcm
        ? "You don use all your Suskii AI messages for today. Abeg come back tomorrow."
        : "You have reached your daily Suskii AI usage limit. Please come back tomorrow.") + form;
    case "month":
      return (pcm
        ? "You don use all your Suskii AI messages for this month. E go start again for the beginning of next month."
        : "You have used your monthly AI allowance. Your allowance will reset at the beginning of next month.") +
        form;
    case "budget":
      return (pcm
        ? "Suskii AI dey rest small now. Abeg try again later."
        : "Suskii AI is taking a short break. Please try again later.") + form;
    case "suspended":
      return (pcm
        ? "Suskii AI no dey available for your account now. Contact support if you think say na mistake."
        : "Suskii AI isn't available on your account right now. Contact support if you think this is a mistake.") +
        form;
    case "minute":
    case "cooldown":
      return pcm
        ? "You dey send message too fast. Abeg wait small, then send am again."
        : "You're sending messages a little fast. Please wait a moment and send it again.";
    default:
      return (pcm ? "This conversation don reach im limit." : "This conversation has reached its limit.") + form;
  }
}
