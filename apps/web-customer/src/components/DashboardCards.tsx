'use client';

import Link from 'next/link';
import type { Locale } from '@/lib/i18n';
import { useShowsMoneyLink } from './MoneyLinksFilter';

export interface DashboardCard {
  title: string;
  body: string;
  /** The page, without the locale prefix. */
  path: string;
}

/** The dashboard's shortcut cards, without the money pages where the country
 * pays providers directly. */
export function DashboardCards({ locale, cards }: { locale: Locale; cards: DashboardCard[] }) {
  const shows = useShowsMoneyLink();
  return (
    <>
      {cards
        .filter((card) => shows(card.path))
        .map((card) => (
          <Link
            key={card.title}
            href={`/${locale}${card.path}`}
            className="rounded-lg border border-outline bg-surface-raised p-xl transition-colors duration-normal ease-standard hover:border-brand-primary dark:border-outline-dark dark:bg-surface-dark-raised dark:hover:border-brand-secondary"
          >
            <h2 className="text-title-large text-ink-primary dark:text-ink-dark-primary">
              {card.title}
            </h2>
            <p className="mt-sm text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
              {card.body}
            </p>
          </Link>
        ))}
    </>
  );
}
