'use client';

import { useId } from 'react';

// Standalone exponent table — intentionally duplicated from the
// (concurrently built) @/lib/money so this component compiles on its own.
const EXPONENTS: Record<string, number> = {
  NGN: 2,
  KES: 2,
  GHS: 2,
  ZAR: 2,
  UGX: 0,
  USD: 2,
};

// Parse a user-typed major-units string into integer minor units without
// ever doing float arithmetic on the result.
function parseToMinor(raw: string, exponent: number): number | null {
  const trimmed = raw.trim();
  if (trimmed === '') return null;
  if (!/^\d+(\.\d+)?$/.test(trimmed)) return null;
  const [whole, frac = ''] = trimmed.split('.');
  if (frac.length > exponent) return null;
  const minorDigits = frac.padEnd(exponent, '0');
  return Number.parseInt(whole + minorDigits, 10);
}

function minorToMajor(minor: number, exponent: number): string {
  const sign = minor < 0 ? '-' : '';
  const digits = String(Math.abs(minor)).padStart(exponent + 1, '0');
  if (exponent === 0) return sign + digits;
  const whole = digits.slice(0, -exponent);
  const frac = digits.slice(-exponent);
  return `${sign}${whole}.${frac}`;
}

export function MoneyField({
  label,
  currency,
  valueMinor,
  onChange,
  hint,
}: {
  label: string;
  currency: string;
  valueMinor: number | null;
  onChange: (minor: number | null) => void;
  hint?: string;
}) {
  const id = useId();
  const exponent = EXPONENTS[currency] ?? 2;
  const display = valueMinor === null ? '' : minorToMajor(valueMinor, exponent);

  return (
    <div className="flex flex-col gap-xs">
      <label
        htmlFor={id}
        className="text-label-large text-ink-primary dark:text-ink-dark-primary"
      >
        {label}
      </label>
      <div className="flex items-center gap-sm rounded-md border border-outline bg-surface-raised px-md py-sm transition-colors duration-normal ease-standard focus-within:border-brand-primary dark:border-outline-dark dark:bg-surface-dark-raised">
        <span className="text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
          {currency}
        </span>
        <input
          id={id}
          type="text"
          inputMode="decimal"
          value={display}
          placeholder={exponent === 0 ? '0' : '0.00'}
          onChange={(e) => onChange(parseToMinor(e.target.value, exponent))}
          className="w-full bg-transparent text-body-large text-ink-primary outline-none placeholder:text-ink-secondary dark:text-ink-dark-primary dark:placeholder:text-ink-dark-secondary"
        />
      </div>
      {hint ? (
        <p className="text-body-small text-ink-secondary dark:text-ink-dark-secondary">{hint}</p>
      ) : null}
    </div>
  );
}
