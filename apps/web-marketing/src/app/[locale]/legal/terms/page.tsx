import type { Metadata } from 'next';
import { getDictionary, isLocale, type Locale } from '@/lib/i18n';
import { PolicyDocument } from '@/components/PolicyDocument';
import { termsOfService } from '@/content/terms-of-service';

type Props = { params: Promise<{ locale: string }> };

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const { locale } = await params;
  if (!isLocale(locale)) return {};
  const dict = await getDictionary(locale);
  return { title: dict.legal.termsTitle };
}

/** The published terms (src/content/terms-of-service.ts); English for every locale. */
export default async function TermsPage({ params }: Props) {
  const { locale } = await params;
  const dict = await getDictionary(locale as Locale);

  return (
    <PolicyDocument
      title={dict.legal.termsTitle}
      updated={termsOfService.updated}
      sections={termsOfService.sections}
    />
  );
}
