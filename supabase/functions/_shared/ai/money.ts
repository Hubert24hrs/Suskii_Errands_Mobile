// Formatting minor units for a model to quote (ai-design §1, rule 2: numbers come from functions).
// The model is given these strings and nothing to do arithmetic on; the output filter then lets an
// amount through only if it is one of them.

const SYMBOLS: Record<string, string> = { NGN: "₦", KES: "KSh ", GHS: "GH₵", ZAR: "R", UGX: "USh " };

export function formatMinor(minor: number | string, code: string, exponent: number): string {
  const value = BigInt(String(minor));
  const negative = value < 0n;
  const abs = negative ? -value : value;
  const scale = 10n ** BigInt(exponent);
  const whole = (abs / scale).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  const fraction = abs % scale;
  const text = fraction === 0n ? whole : `${whole}.${fraction.toString().padStart(exponent, "0")}`;
  return `${negative ? "-" : ""}${SYMBOLS[code] ?? `${code} `}${text}`;
}

/** The digits of an amount, for comparing what a reply quotes with what a tool returned. */
export function amountDigits(text: string): string {
  return text.replace(/\.0+$/, "").replace(/[^\d.]/g, "").replace(/\.$/, "");
}
