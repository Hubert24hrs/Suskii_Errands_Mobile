import Link from 'next/link';
import { getDictionary, isLocale, type Locale } from '@/lib/i18n';

type Props = { params: Promise<{ locale: string }> };

const cardHrefs = [
  '/requests/new',
  '/concierge',
  '/wallet',
  '/referrals',
  '/requests',
  '/promos',
  '/support',
  '/settings',
] as const;

export default async function DashboardPage({ params }: Props) {
  const { locale } = await params;
  if (!isLocale(locale)) return null;
  const dict = await getDictionary(locale as Locale);

  return (
    <div className="mx-auto w-full max-w-5xl px-lg py-xxxl">
      <h1 className="text-headline-medium text-ink-primary dark:text-ink-dark-primary">
        {dict.dashboard.greeting}
      </h1>
      <p className="mt-md text-body-large text-ink-secondary dark:text-ink-dark-secondary">
        {dict.dashboard.subtitle}
      </p>
      <div className="mt-xxl grid gap-xl sm:grid-cols-2">
        {dict.dashboard.cards.map((card, i) => (
          <Link
            key={card.title}
            href={`/${locale}${cardHrefs[i]}`}
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
      </div>
    </div>
  );
}
