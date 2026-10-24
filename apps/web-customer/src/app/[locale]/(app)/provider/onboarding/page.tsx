import { notFound } from 'next/navigation';
import { getDictionary, isLocale, type Locale } from '@/lib/i18n';
import { OnboardingClient } from './OnboardingClient';

export default async function ProviderOnboardingPage({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  if (!isLocale(locale)) notFound();
  const dict = await getDictionary(locale as Locale);
  return <OnboardingClient locale={locale as Locale} dict={dict} />;
}
