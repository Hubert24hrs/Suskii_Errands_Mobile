import { notFound } from 'next/navigation';
import { getDictionary, isLocale, type Locale } from '@/lib/i18n';
import { BusinessClient } from './BusinessClient';

export default async function ProviderBusinessPage({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  if (!isLocale(locale)) notFound();
  const dict = await getDictionary(locale as Locale);
  return <BusinessClient locale={locale as Locale} dict={dict} />;
}
