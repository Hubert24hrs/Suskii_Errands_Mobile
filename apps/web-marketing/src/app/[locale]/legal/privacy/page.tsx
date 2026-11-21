import type { Metadata } from 'next';
import { getDictionary, isLocale, type Locale } from '@/lib/i18n';
import { PolicyDocument } from '@/components/PolicyDocument';
import { privacyPolicy } from '@/content/privacy-policy';

type Props = { params: Promise<{ locale: string }> };

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const { locale } = await params;
  if (!isLocale(locale)) return {};
  const dict = await getDictionary(locale);
  return { title: dict.legal.privacyTitle };
}

/** The published policy (src/content/privacy-policy.ts); English for every locale. */
export default async function PrivacyPage({ params }: Props) {
  const { locale } = await params;
  const dict = await getDictionary(locale as Locale);

  return (
    <PolicyDocument
      title={dict.legal.privacyTitle}
      updated={privacyPolicy.updated}
      sections={privacyPolicy.sections}
    />
  );
}
