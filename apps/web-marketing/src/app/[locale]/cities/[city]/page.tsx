import type { Metadata } from 'next';
import { notFound } from 'next/navigation';
import { getDictionary, isLocale, type Locale } from '@/lib/i18n';
import { cities, isCity, type CitySlug } from '@/lib/cities';
import { Container } from '@/components/Container';
import { StoreBadges } from '@/components/StoreBadges';

type Props = { params: Promise<{ locale: string; city: string }> };

export function generateStaticParams() {
  return cities.map((city) => ({ city }));
}

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const { locale, city } = await params;
  if (!isLocale(locale) || !isCity(city)) return {};
  const dict = await getDictionary(locale);
  const data = dict.city[city];
  return { title: data.name, description: data.tagline };
}

export default async function CityPage({ params }: Props) {
  const { locale, city } = await params;
  if (!isCity(city)) notFound();
  const dict = await getDictionary(locale as Locale);
  const data = dict.city[city as CitySlug];

  return (
    <Container className="py-xxxl text-center">
      <h1 className="text-display-small text-ink-primary dark:text-ink-dark-primary">{data.name}</h1>
      <p className="mx-auto mt-md max-w-2xl text-body-large text-ink-secondary dark:text-ink-dark-secondary">
        {data.tagline}
      </p>
      <div className="mt-xxxl">
        <StoreBadges
          appStoreLabel={dict.common.appStore}
          googlePlayLabel={dict.common.googlePlay}
          downloadLabel={dict.cities.cta}
        />
      </div>
    </Container>
  );
}
