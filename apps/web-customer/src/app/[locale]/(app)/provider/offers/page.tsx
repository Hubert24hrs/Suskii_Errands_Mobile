import { notFound } from 'next/navigation';
import { getDictionary, isLocale, type Locale } from '@/lib/i18n';
import { MyOffersClient } from './MyOffersClient';

export default async function MyOffersPage({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  if (!isLocale(locale)) notFound();
  const dict = await getDictionary(locale as Locale);
  return <MyOffersClient locale={locale as Locale} dict={dict} />;
}
