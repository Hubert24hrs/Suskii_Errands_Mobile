// Standalone exponent/symbol table — intentionally duplicated from the
// (concurrently built) @/lib/money so this component compiles on its own.
const CURRENCIES: Record<string, { exponent: number; symbol: string }> = {
  NGN: { exponent: 2, symbol: '₦' },
  KES: { exponent: 2, symbol: 'KSh' },
  GHS: { exponent: 2, symbol: 'GH₵' },
  ZAR: { exponent: 2, symbol: 'R' },
  UGX: { exponent: 0, symbol: 'USh' },
  USD: { exponent: 2, symbol: '$' },
};

export function formatMoney(amountMinor: number, currency: string): string {
  const meta = CURRENCIES[currency] ?? { exponent: 2, symbol: `${currency} ` };
  const major = amountMinor / 10 ** meta.exponent;
  const formatted = major.toLocaleString('en-NG', {
    minimumFractionDigits: meta.exponent,
    maximumFractionDigits: meta.exponent,
  });
  return `${meta.symbol}${formatted}`;
}

export function MoneyText({
  amountMinor,
  currency,
  className,
}: {
  amountMinor: number;
  currency: string;
  className?: string;
}) {
  return <span className={className}>{formatMoney(amountMinor, currency)}</span>;
}
