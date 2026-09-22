import type { Metadata } from 'next';
import { getDictionary, isLocale, type Locale } from '@/lib/i18n';
import { FeatureGrid } from '@/components/FeatureGrid';
import { Container } from '@/components/Container';

type Props = { params: Promise<{ locale: string }> };

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const { locale } = await params;
  if (!isLocale(locale)) return {};
  const dict = await getDictionary(locale);
  return { title: dict.howItWorks.title, description: dict.howItWorks.subtitle };
}

export default async function HowItWorksPage({ params }: Props) {
  const { locale } = await params;
  const dict = await getDictionary(locale as Locale);

  return (
    <>
      <Container className="py-xxxl">
        <h1 className="text-display-small text-ink-primary dark:text-ink-dark-primary">
          {dict.howItWorks.title}
        </h1>
        <p className="mt-md max-w-2xl text-body-large text-ink-secondary dark:text-ink-dark-secondary">
          {dict.howItWorks.subtitle}
        </p>
      </Container>
      <FeatureGrid
        title={dict.howItWorks.forCustomersTitle}
        items={dict.howItWorks.customerSteps}
        columns={2}
      />
      <FeatureGrid
        title={dict.howItWorks.forProvidersTitle}
        items={dict.howItWorks.providerSteps}
        columns={2}
      />
    </>
  );
}
