'use client';

// Form pieces shared by the Services and AI usage pages: the console's field styling, and US-dollar
// amounts held as integer micro-dollars (the backend's `cost_micros`), converted with integer
// arithmetic only.

import type { ReactNode } from 'react';

export const inputClass =
  'w-full rounded-md border border-outline bg-surface px-md py-sm text-body-large text-ink-primary outline-none transition-colors duration-normal ease-standard focus:border-brand-primary dark:border-outline-dark dark:bg-surface-dark dark:text-ink-dark-primary';
export const labelClass = 'text-label-large text-ink-primary dark:text-ink-dark-primary';
export const primaryButton =
  'rounded-md bg-brand-primary px-xl py-sm text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong disabled:opacity-50';
export const secondaryButton =
  'rounded-md border border-outline px-md py-xs text-label-large text-ink-primary transition-colors duration-normal ease-standard hover:bg-surface-muted disabled:opacity-50 dark:border-outline-dark dark:text-ink-dark-primary dark:hover:bg-surface-dark-muted';
export const panelClass =
  'flex flex-col gap-md rounded-lg border border-outline bg-surface-raised p-xl dark:border-outline-dark dark:bg-surface-dark-raised';

// A real <label>, so the text names its control for screen readers.
export function Field({ label, hint, children }: { label: string; hint?: string; children: ReactNode }) {
  return (
    <label className="flex flex-col gap-xs">
      <span className={labelClass}>{label}</span>
      {children}
      {hint ? <span className="text-body-small text-ink-secondary dark:text-ink-dark-secondary">{hint}</span> : null}
    </label>
  );
}

/** $1.2345 from 1234500 micro-dollars; four decimals, because a message costs fractions of a cent. */
export function usd(micros: number): string {
  const sign = micros < 0 ? '-' : '';
  const abs = Math.abs(Math.trunc(micros));
  const dollars = Math.floor(abs / 1_000_000);
  const fraction = String(abs % 1_000_000).padStart(6, '0').slice(0, 4);
  return `${sign}$${dollars.toLocaleString('en-GB')}.${fraction}`;
}

/** "2.50" -> 2500000; null for anything that is not a plain non-negative amount. */
export function microsFromUsd(text: string): number | null {
  const match = /^\s*(\d{1,7})(?:\.(\d{1,6}))?\s*$/.exec(text);
  if (!match) return null;
  return Number(match[1]) * 1_000_000 + Number((match[2] ?? '').padEnd(6, '0'));
}

/** "2.5" for 2500000: the inverse, for prefilling an input. */
export function usdInput(micros: number): string {
  const dollars = Math.floor(micros / 1_000_000);
  const fraction = String(micros % 1_000_000).padStart(6, '0').replace(/0+$/, '');
  return fraction ? `${dollars}.${fraction}` : String(dollars);
}

/** Downloads rows as a CSV file named [name]. */
export function downloadCsv(name: string, header: string[], rows: Array<Array<string | number>>): void {
  const cell = (v: string | number) => {
    const s = String(v);
    return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  };
  const csv = [header, ...rows].map((r) => r.map(cell).join(',')).join('\n');
  const url = URL.createObjectURL(new Blob([csv], { type: 'text/csv;charset=utf-8' }));
  const a = document.createElement('a');
  a.href = url;
  a.download = name;
  a.click();
  URL.revokeObjectURL(url);
}
