'use client';

// Shared pieces of the provider screens: the section tabs, button styles and
// small formatting helpers. The screens mirror the mobile app's provider side.

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import type { Dictionary } from '@/lib/i18n/en';
import type { Locale } from '@/lib/i18n';
import { ModeSwitchButton } from '@/components/ModeSwitch';

export { categoryLabel, errorText, formatDateTime, statusLabel, statusTone, urgencyLabel } from '../requests/_shared';

export const btnPrimary =
  'rounded-md bg-brand-primary px-xl py-sm text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong disabled:opacity-50';
export const btnSecondary =
  'rounded-md border border-outline px-xl py-sm text-label-large text-ink-primary transition-colors duration-normal ease-standard hover:border-brand-primary disabled:opacity-50 dark:border-outline-dark dark:text-ink-dark-primary';
export const btnDanger =
  'rounded-md border border-error px-xl py-sm text-label-large text-error transition-colors duration-normal ease-standard hover:bg-error/10 disabled:opacity-50 dark:border-error-dark dark:text-error-dark';
export const card =
  'rounded-lg border border-outline bg-surface-raised p-xl dark:border-outline-dark dark:bg-surface-dark-raised';
export const inputClass =
  'w-full rounded-md border border-outline bg-surface-raised px-md py-sm text-body-large text-ink-primary dark:border-outline-dark dark:bg-surface-dark-raised dark:text-ink-dark-primary';
export const labelClass = 'text-label-large text-ink-primary dark:text-ink-dark-primary';
export const mutedText = 'text-body-small text-ink-secondary dark:text-ink-dark-secondary';
export const sectionTitle = 'text-title-large text-ink-primary dark:text-ink-dark-primary';
export const pageTitle = 'text-headline-medium text-ink-primary dark:text-ink-dark-primary';

/** Replaces `{name}` placeholders. */
export function fill(template: string, values: Record<string, string | number>): string {
  return template.replace(/\{(\w+)\}/g, (match, key: string) =>
    key in values ? String(values[key]) : match,
  );
}

export function ProviderNav({ locale, dict }: { locale: Locale; dict: Dictionary }) {
  const pathname = usePathname();
  const base = `/${locale}/provider`;
  const tabs: [string, string][] = [
    [dict.provider.nav.feed, base],
    [dict.provider.nav.offers, `${base}/offers`],
    [dict.provider.nav.jobs, `${base}/jobs`],
    [dict.provider.nav.earnings, `${base}/earnings`],
    [dict.provider.nav.tools, `${base}/tools`],
    [dict.provider.nav.business, `${base}/business`],
    [dict.provider.nav.verification, `${base}/verification`],
  ];
  return (
    <nav
      aria-label={dict.provider.modeProvider}
      className="-mx-lg mb-xl flex gap-xs overflow-x-auto border-b border-outline px-lg dark:border-outline-dark"
    >
      {tabs.map(([label, href]) => {
        const active = href === base ? pathname === base : pathname.startsWith(href);
        return (
          <Link
            key={href}
            href={href}
            aria-current={active ? 'page' : undefined}
            className={`whitespace-nowrap border-b-2 px-md py-sm text-label-large ${
              active
                ? 'border-brand-primary text-brand-primary dark:border-brand-secondary dark:text-brand-secondary'
                : 'border-transparent text-ink-secondary hover:text-ink-primary dark:text-ink-dark-secondary dark:hover:text-ink-dark-primary'
            }`}
          >
            {label}
          </Link>
        );
      })}
      <ModeSwitchButton
        locale={locale}
        dict={dict}
        testId="mode-switch-tabs"
        className="whitespace-nowrap px-md py-sm text-label-large text-brand-primary sm:hidden dark:text-brand-secondary"
      />
    </nav>
  );
}

/** One page's frame: the tabs, then the content. */
export function ProviderPage({
  locale,
  dict,
  children,
}: {
  locale: Locale;
  dict: Dictionary;
  children: React.ReactNode;
}) {
  return (
    <div className="mx-auto w-full max-w-5xl px-lg py-xl">
      <ProviderNav locale={locale} dict={dict} />
      <div className="flex flex-col gap-xl">{children}</div>
    </div>
  );
}

/** A short-lived confirmation line under an action. */
export function Notice({ text, tone = 'success' }: { text?: string; tone?: 'success' | 'error' }) {
  if (!text) return null;
  return (
    <p
      role={tone === 'error' ? 'alert' : 'status'}
      className={`text-body-small ${tone === 'error' ? 'text-error dark:text-error-dark' : 'text-success dark:text-success-dark'}`}
    >
      {text}
    </p>
  );
}
