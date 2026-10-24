import { notFound } from 'next/navigation';
import { getDictionary, isLocale, type Locale } from '@/lib/i18n';
import { ChatClient } from '../../../../requests/[id]/chat/ChatClient';

export default async function ProviderJobChatPage({ params }: { params: Promise<{ locale: string; id: string }> }) {
  const { locale, id } = await params;
  if (!isLocale(locale)) notFound();
  const dict = await getDictionary(locale as Locale);
  return <ChatClient locale={locale as Locale} jobId={id} dict={dict} backBase="provider/jobs" />;
}
