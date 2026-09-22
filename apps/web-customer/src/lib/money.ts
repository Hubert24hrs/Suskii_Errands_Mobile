// Money helpers mirroring packages/suskii_domain/lib/src/money.dart.
// Money is ALWAYS integer minor units + an ISO 4217 currency code — never
// floating point. Derived amounts (commission, fees, payouts) arrive from
// server-style quote objects; this file only formats and parses.

export interface MoneyLike {
  amountMinor: number;
  currency: string;
}

/** ISO 4217 minor-unit exponents that differ from the common default of 2. */
const EXPONENTS: Record<string, number> = {
  XOF: 0, XAF: 0, JPY: 0, KRW: 0, UGX: 0, RWF: 0,
  VUV: 0, CLP: 0, GNF: 0,
  BHD: 3, JOD: 3, KWD: 3, OMR: 3, TND: 3, LYD: 3, IQD: 3,
};

/**
 * Known two-exponent codes. An unknown code throws instead of silently
 * defaulting to 2 (review C.6: a missing zero-exponent currency would render
 * 100× too small). Extend this table when adding a currency.
 */
const TWO_EXPONENT = new Set([
  'NGN', 'KES', 'GHS', 'ZAR', 'USD', 'EUR', 'GBP',
  'CAD', 'AUD', 'NZD', 'CHF', 'SEK', 'NOK', 'DKK',
  'INR', 'BRL', 'MXN', 'ZMW', 'TZS', 'EGP', 'MAD',
]);

export function exponentOf(currency: string): number {
  const code = currency.toUpperCase();
  const known = EXPONENTS[code];
  if (known !== undefined) return known;
  if (TWO_EXPONENT.has(code)) return 2;
  throw new Error(
    `Unknown currency exponent for ${code} — add it to the exponent table ` +
      'instead of defaulting to 2.',
  );
}

function pow10(exponent: number): number {
  let factor = 1;
  for (let i = 0; i < exponent; i++) factor *= 10;
  return factor;
}

const SYMBOLS: Record<string, string> = {
  NGN: '₦',
  KES: 'KSh ',
  GHS: 'GH₵',
  ZAR: 'R',
  UGX: 'USh ',
  USD: '$',
  EUR: '€',
  GBP: '£',
  XOF: 'CFA ',
  XAF: 'FCFA ',
};

export function currencySymbol(currency: string): string {
  const code = currency.toUpperCase();
  return SYMBOLS[code] ?? `${code} `;
}

/**
 * Locale-aware display string, e.g. `₦12,500.00`, `CFA 4,500`, `-$5.25`.
 * Integer math only — the minor-unit value never goes through a float
 * division.
 */
export function formatMoney(
  money: MoneyLike,
  locale = 'en-NG',
): string {
  const exp = exponentOf(money.currency);
  const sign = money.amountMinor < 0 ? '-' : '';
  const abs = Math.abs(money.amountMinor);
  const factor = pow10(exp);
  const intPart = Math.floor(abs / factor);
  const grouped = intPart.toLocaleString(locale);
  const symbol = currencySymbol(money.currency);
  if (exp === 0) return `${sign}${symbol}${grouped}`;
  const frac = (abs % factor).toString().padStart(exp, '0');
  return `${sign}${symbol}${grouped}.${frac}`;
}

/** Whole major units → minor units (integer input only). */
export function minorUnitsFromMajor(majorUnits: number, currency: string): number {
  if (!Number.isInteger(majorUnits)) {
    throw new Error('minorUnitsFromMajor expects an integer — use parseMajorUnits for text.');
  }
  return majorUnits * pow10(exponentOf(currency));
}

/**
 * Parses user-typed major units ("12500", "12,500.50", "4500.7") into integer
 * minor units using string math only — no float conversion of the value.
 * Throws on malformed input or more decimals than the currency supports.
 */
export function parseMajorUnits(input: string, currency: string): number {
  const exp = exponentOf(currency);
  const cleaned = input.trim().replace(/[,\s]/g, '');
  const match = /^(-?)(\d+)(?:\.(\d+))?$/.exec(cleaned);
  if (!match) throw new Error(`Invalid amount: ${input}`);
  const [, sign, intPart, fracPart = ''] = match;
  if (fracPart.length > exp) {
    throw new Error(
      `Too many decimal places for ${currency} (exponent ${exp}): ${input}`,
    );
  }
  const frac = fracPart.padEnd(exp, '0');
  // String concatenation + one integer parse: no float math on minor units.
  const minor = Number.parseInt(`${intPart}${frac}`, 10);
  if (!Number.isSafeInteger(minor)) throw new Error(`Amount too large: ${input}`);
  return sign === '-' ? -minor : minor;
}

function assertSameCurrency(a: MoneyLike, b: MoneyLike): void {
  if (a.currency.toUpperCase() !== b.currency.toUpperCase()) {
    throw new Error(`Currency mismatch: ${a.currency} vs ${b.currency}`);
  }
}

export function moneyAdd(a: MoneyLike, b: MoneyLike): MoneyLike {
  assertSameCurrency(a, b);
  return { amountMinor: a.amountMinor + b.amountMinor, currency: a.currency };
}

export function moneySub(a: MoneyLike, b: MoneyLike): MoneyLike {
  assertSameCurrency(a, b);
  return { amountMinor: a.amountMinor - b.amountMinor, currency: a.currency };
}

export function moneyCompare(a: MoneyLike, b: MoneyLike): number {
  assertSameCurrency(a, b);
  return a.amountMinor - b.amountMinor;
}
