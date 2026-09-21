import Link from 'next/link';
import type { Dictionary } from '@/lib/i18n/en';
import type { Locale } from '@/lib/i18n';
import { LocaleSwitcher } from './LocaleSwitcher';

export function AppHeader({ locale, dict }: { locale: Locale; dict: Dictionary }) {
  return (
    <header className="border-b border-outline bg-surface-raised dark:border-outline-dark dark:bg-surface-dark-raised">
      <div className="mx-auto flex h-16 w-full max-w-5xl items-center justify-between px-lg">
        <Link
          href={`/${locale}`}
          className="flex items-center gap-sm text-title-large text-ink-primary dark:text-ink-dark-primary"
        >
          <span className="flex h-8 w-8 items-center justify-center rounded-sm bg-brand-primary font-bold text-brand-on-primary">
            S
          </span>
          {dict.header.appName}
        </Link>
        <nav className="hidden items-center gap-lg md:flex">
          {(
            [
              [dict.requests.listTitle, '/requests'],
              [dict.messages.title, '/messages'],
              [dict.wallet.title, '/wallet'],
              [dict.settings.title, '/settings'],
            ] as const
          ).map(([label, href]) => (
            <Link
              key={href}
              href={`/${locale}${href}`}
              className="text-label-large text-ink-secondary transition-colors duration-normal ease-standard hover:text-brand-primary dark:text-ink-dark-secondary dark:hover:text-brand-secondary"
            >
              {label}
            </Link>
          ))}
        </nav>
        <div className="flex items-center gap-md">
          <LocaleSwitcher locale={locale} />
          {/* TODO(M9): wire to real auth once @supabase/ssr lands */}
          <button
            type="button"
            className="rounded-md bg-brand-primary px-lg py-sm text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong"
          >
            {dict.header.signIn}
          </button>
        </div>
      </div>
    </header>
  );
}
