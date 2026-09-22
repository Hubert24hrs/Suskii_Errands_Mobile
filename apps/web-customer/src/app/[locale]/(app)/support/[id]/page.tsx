import { notFound } from 'next/navigation';
import { getDictionary, isLocale, type Locale } from '@/lib/i18n';
import { SupportThreadClient } from './SupportThreadClient';

export default async function SupportThreadPage({
  params,
}: {
  params: Promise<{ locale: string; id: string }>;
}) {
  const { locale, id } = await params;
  if (!isLocale(locale)) notFound();
  const dict = await getDictionary(locale as Locale);
  return <SupportThreadClient locale={locale as Locale} dict={dict} ticketId={id} />;
}
