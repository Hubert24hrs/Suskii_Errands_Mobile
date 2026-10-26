// Redaction before any model call (ai-design §6.1). What a model sees, and what is stored, is
// the redacted form; the real values exist only in the request that carried them.
//
// The gate is recall, not precision: a miss is a data incident, an over-redaction is an
// inconvenience. So ambiguous digit runs are redacted as numbers rather than guessed at, and no
// placeholder is ever rehydrated here: no concierge tool takes a phone number, an email, an ID, a
// card or an account (§6.1's table), and places come from the map picker, not from typed text.

export type Kind = "EMAIL" | "CARD" | "PHONE" | "GOV_ID" | "ACCOUNT" | "NUMBER";

export interface Redaction {
  text: string;
  counts: Partial<Record<Kind, number>>;
}

const EMAIL = /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g;
// Digit runs that may carry spaces, dots or dashes between groups ("0803 123 4567").
const DIGIT_RUN = /\+?\d(?:[\d\s.-]{5,}\d)/g;

function luhn(digits: string): boolean {
  let sum = 0;
  for (let i = 0; i < digits.length; i++) {
    let d = Number(digits[digits.length - 1 - i]);
    if (i % 2 === 1) {
      d *= 2;
      if (d > 9) d -= 9;
    }
    sum += d;
  }
  return sum % 10 === 0;
}

/** What a run of digits most likely is. Anything nine digits or longer is redacted. */
export function classify(raw: string): Kind | null {
  const plus = raw.trim().startsWith("+");
  const digits = raw.replace(/\D/g, "");
  if (digits.length < 9) return null;
  if (digits.length >= 13 && digits.length <= 19 && luhn(digits)) return "CARD";
  // Nigerian mobiles: 0[789][01]XXXXXXXX, or 234 for the 0. Kenya, Ghana, South Africa and
  // Uganda numbers in international form are caught by the plus or the calling code.
  if (/^0[789][01]\d{8}$/.test(digits) || /^234[789][01]\d{8}$/.test(digits)) return "PHONE";
  if (plus || /^(254|233|27|256)\d{8,9}$/.test(digits)) return "PHONE";
  if (digits.length === 11) return "GOV_ID"; // NIN and BVN are both eleven digits.
  if (digits.length === 10) return "ACCOUNT"; // NUBAN.
  return "NUMBER";
}

export function redact(input: string): Redaction {
  const counts: Partial<Record<Kind, number>> = {};
  const next = (kind: Kind) => {
    counts[kind] = (counts[kind] ?? 0) + 1;
    return `<${kind}_${counts[kind]}>`;
  };
  let text = input.replace(EMAIL, () => next("EMAIL"));
  text = text.replace(DIGIT_RUN, (run) => {
    const kind = classify(run);
    return kind ? next(kind) : run;
  });
  return { text, counts };
}
