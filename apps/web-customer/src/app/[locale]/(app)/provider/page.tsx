import { notFound } from 'next/navigation';
import { getDictionary, isLocale, type Locale } from '@/lib/i18n';
import { ProviderFeedClient } from './ProviderFeedClient';

export default async function ProviderHomePage({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  if (!isLocale(locale)) notFound();
  const dict = await getDictionary(locale as Locale);
  return <ProviderFeedClient locale={locale as Locale} dict={dict} />;
}
