import { formatMoney as formatMoneyLike } from '@/lib/money';

/** Integer-only formatting from @/lib/money; the sign goes before the symbol (-₦21,750.00). */
export function formatMoney(amountMinor: number, currency: string): string {
  return formatMoneyLike({ amountMinor, currency });
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
