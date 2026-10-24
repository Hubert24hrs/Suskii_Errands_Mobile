'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { locales, localeNames, type Locale } from '@/lib/i18n';

export function LocaleSwitcher({ locale }: { locale: Locale }) {
  const pathname = usePathname();

  return (
    <div className="flex gap-xs text-body-small" aria-label="Language">
      {locales.map((l) => {
        const href = `/${l}${pathname.replace(/^\/(en|pcm)/, '')}`;
        const active = l === locale;
        return (
          <Link
            key={l}
            href={href}
            aria-current={active ? 'true' : undefined}
            className={
              active
                ? 'whitespace-nowrap rounded-sm px-sm py-xs font-semibold text-brand-primary dark:text-brand-secondary'
                : 'whitespace-nowrap rounded-sm px-sm py-xs text-ink-secondary hover:text-ink-primary dark:text-ink-dark-secondary dark:hover:text-ink-dark-primary'
            }
          >
            {localeNames[l]}
          </Link>
        );
      })}
    </div>
  );
}
