import { getDictionary, isLocale, type Locale } from '@/lib/i18n';
import { DashboardCards } from '@/components/DashboardCards';
import { HomeServicePicker } from './HomeServicePicker';
import { ProviderModeCard } from './ProviderModeCard';

type Props = { params: Promise<{ locale: string }> };

const cardHrefs = [
  '/requests/new',
  '/concierge',
  '/meet',
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
      <HomeServicePicker locale={locale as Locale} dict={dict} />
      <div className="mt-xxl grid gap-xl sm:grid-cols-2">
        <DashboardCards
          locale={locale as Locale}
          cards={dict.dashboard.cards.slice(0, cardHrefs.length).map((card, i) => ({
            title: card.title,
            body: card.body,
            path: cardHrefs[i],
          }))}
        />
        <ProviderModeCard locale={locale as Locale} dict={dict} />
      </div>
    </div>
  );
}
