import type { ReactNode } from 'react';
import { notFound } from 'next/navigation';
import { getDictionary, isLocale, type Locale } from '@/lib/i18n';
import { Providers } from '@/components/Providers';
import { AppHeader } from '@/components/AppHeader';
import { DeletionPendingNotice } from '@/components/DeletionPendingNotice';
import { RoleSelectionGate } from '@/components/RoleSelectionGate';

export default async function AppLayout({
  children,
  params,
}: {
  children: ReactNode;
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  if (!isLocale(locale)) notFound();
  const dict = await getDictionary(locale as Locale);

  return (
    <Providers>
      <AppHeader locale={locale as Locale} dict={dict} />
      <DeletionPendingNotice locale={locale as Locale} dict={dict} />
      <RoleSelectionGate locale={locale as Locale} dict={dict} />
      <main>{children}</main>
    </Providers>
  );
}
