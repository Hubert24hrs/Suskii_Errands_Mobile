import type { Metadata } from 'next';
import { getDictionary, isLocale, type Locale } from '@/lib/i18n';
import { FeatureGrid } from '@/components/FeatureGrid';
import { Container } from '@/components/Container';
import { StoreBadges } from '@/components/StoreBadges';

type Props = { params: Promise<{ locale: string }> };

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const { locale } = await params;
  if (!isLocale(locale)) return {};
  const dict = await getDictionary(locale);
  return { title: dict.referrals.title, description: dict.referrals.subtitle };
}

export default async function ReferralsPage({ params }: Props) {
  const { locale } = await params;
  const dict = await getDictionary(locale as Locale);

  return (
    <>
      <Container className="py-xxxl">
        <h1 className="text-display-small text-ink-primary dark:text-ink-dark-primary">
          {dict.referrals.title}
        </h1>
        <p className="mt-md max-w-2xl text-body-large text-ink-secondary dark:text-ink-dark-secondary">
          {dict.referrals.subtitle}
        </p>
      </Container>
      <FeatureGrid items={dict.referrals.steps} />
      <Container className="pb-xxxl text-center">
        <StoreBadges
          appStoreLabel={dict.common.appStore}
          googlePlayLabel={dict.common.googlePlay}
          downloadLabel={dict.referrals.cta}
        />
      </Container>
    </>
  );
}
