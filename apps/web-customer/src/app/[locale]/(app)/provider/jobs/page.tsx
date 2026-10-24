import { notFound } from 'next/navigation';
import { getDictionary, isLocale, type Locale } from '@/lib/i18n';
import { ProviderJobsClient } from './ProviderJobsClient';

export default async function ProviderJobsPage({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  if (!isLocale(locale)) notFound();
  const dict = await getDictionary(locale as Locale);
  return <ProviderJobsClient locale={locale as Locale} dict={dict} />;
}
