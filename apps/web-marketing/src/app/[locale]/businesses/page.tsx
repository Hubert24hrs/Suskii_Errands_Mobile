import Link from 'next/link';
import type { Metadata } from 'next';
import { getDictionary, isLocale, type Locale } from '@/lib/i18n';
import { FeatureGrid } from '@/components/FeatureGrid';
import { Container } from '@/components/Container';

type Props = { params: Promise<{ locale: string }> };

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const { locale } = await params;
  if (!isLocale(locale)) return {};
  const dict = await getDictionary(locale);
  return { title: dict.businesses.title, description: dict.businesses.subtitle };
}

export default async function BusinessesPage({ params }: Props) {
  const { locale } = await params;
  const dict = await getDictionary(locale as Locale);

  return (
    <>
      <Container className="py-xxxl">
        <h1 className="text-display-small text-ink-primary dark:text-ink-dark-primary">
          {dict.businesses.title}
        </h1>
        <p className="mt-md max-w-2xl text-body-large text-ink-secondary dark:text-ink-dark-secondary">
          {dict.businesses.subtitle}
        </p>
      </Container>
      <FeatureGrid items={dict.businesses.points} />
      <Container className="pb-xxxl">
        <Link
          href={`/${locale}/contact`}
          className="inline-block rounded-md bg-brand-primary px-xl py-md text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong"
        >
          {dict.businesses.cta}
        </Link>
      </Container>
    </>
  );
}
