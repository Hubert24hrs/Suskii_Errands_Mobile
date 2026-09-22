import { notFound } from 'next/navigation';
import { getDictionary, isLocale, type Locale } from '@/lib/i18n';
import { DisputesClient } from './DisputesClient';

export default async function DisputesPage({
  params,
  searchParams,
}: {
  params: Promise<{ locale: string }>;
  searchParams: Promise<{ open?: string }>;
}) {
  const { locale } = await params;
  if (!isLocale(locale)) notFound();
  const dict = await getDictionary(locale as Locale);
  const { open } = await searchParams;
  return <DisputesClient locale={locale as Locale} dict={dict} openJobId={open ?? null} />;
}
