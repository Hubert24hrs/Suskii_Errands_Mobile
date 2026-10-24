import { notFound } from 'next/navigation';
import { getDictionary, isLocale, type Locale } from '@/lib/i18n';
import { MeetDetailClient } from './MeetDetailClient';

export default async function MeetDetailPage({
  params,
}: {
  params: Promise<{ locale: string; id: string }>;
}) {
  const { locale, id } = await params;
  if (!isLocale(locale)) notFound();
  const dict = await getDictionary(locale as Locale);
  return <MeetDetailClient locale={locale as Locale} meetupId={id} dict={dict} />;
}
