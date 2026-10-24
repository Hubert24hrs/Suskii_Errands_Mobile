import { notFound } from 'next/navigation';
import { getDictionary, isLocale, type Locale } from '@/lib/i18n';
import { JobExecutionClient } from './JobExecutionClient';

export default async function ProviderJobPage({ params }: { params: Promise<{ locale: string; id: string }> }) {
  const { locale, id } = await params;
  if (!isLocale(locale)) notFound();
  const dict = await getDictionary(locale as Locale);
  return <JobExecutionClient locale={locale as Locale} jobId={id} dict={dict} />;
}
