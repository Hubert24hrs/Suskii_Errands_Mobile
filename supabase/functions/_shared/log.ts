// Structured JSON logs. Callers pass only non-personal fields; phone numbers go through
// maskPhone() and OTPs, tokens and nonces are never logged (data-flow rule 3).

type Level = "info" | "warn" | "error";

export function log(level: Level, event: string, fields: Record<string, unknown> = {}): void {
  const line = JSON.stringify({ level, event, ts: new Date().toISOString(), ...fields });
  if (level === "error") console.error(line);
  else if (level === "warn") console.warn(line);
  else console.log(line);
}

/** Keeps the calling code and the last two digits: "234•••••••78". */
export function maskPhone(digits: string): string {
  if (digits.length <= 5) return "•".repeat(digits.length);
  return digits.slice(0, 3) + "•".repeat(digits.length - 5) + digits.slice(-2);
}
