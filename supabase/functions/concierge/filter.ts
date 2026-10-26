// The output filter (ai-design §6.2): what leaves for the customer, whatever the model wrote.
//
// - Links: only to the app's own domain. A link is how a scam travels in an assistant's voice.
// - Phone numbers, accounts, cards and IDs: removed. The reply is redacted like the input.
// - Amounts: only ones a tool returned this turn. A number the model worked out itself is the
//   thing §1 rule 2 exists to stop, and is reported so the caller can ask again.

import { amountDigits } from "../_shared/ai/money.ts";
import { redact } from "../_shared/ai/redact.ts";

const URL = /\b(?:https?:\/\/|www\.)[^\s)]+/gi;
const ALLOWED_HOST = /^(?:https?:\/\/)?(?:www\.|app\.)?suskiierrand\.com(?:[/?#]|$)/i;
const AMOUNT =
  /(?:₦|NGN|N(?=\d)|KSh|KES|GH₵|GHS|USh|UGX|ZAR|\bR(?=\s?\d))\s?\d[\d,]*(?:\.\d+)?|\d[\d,]*(?:\.\d+)?\s?(?:naira|shillings?|cedis?|rand)\b/gi;

export interface Filtered {
  reply: string;
  removedLinks: number;
  redacted: number;
  unknownAmounts: string[];
}

export function filterReply(reply: string, allowedAmounts: string[]): Filtered {
  let removedLinks = 0;
  let text = reply.replace(URL, (url) => {
    if (ALLOWED_HOST.test(url)) return url;
    removedLinks++;
    return "";
  });
  const r = redact(text);
  text = r.text.replace(/<(?:EMAIL|CARD|PHONE|GOV_ID|ACCOUNT|NUMBER)_\d+>/g, "[removed]");
  const redacted = Object.values(r.counts).reduce((a, b) => a + (b ?? 0), 0);

  const allowed = new Set(allowedAmounts.map(amountDigits));
  const unknownAmounts = [...text.matchAll(AMOUNT)]
    .map((m) => m[0])
    .filter((a) => !allowed.has(amountDigits(a)));
  return { reply: text.replace(/\s{2,}/g, " ").trim(), removedLinks, redacted, unknownAmounts };
}
