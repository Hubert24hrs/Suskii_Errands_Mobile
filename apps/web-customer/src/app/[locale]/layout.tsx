import type { Metadata } from 'next';
import type { ReactNode } from 'react';
import { notFound } from 'next/navigation';
import { getDictionary, isLocale, locales } from '@/lib/i18n';
import '../globals.css';
import { bodyFont, displayFont } from '../fonts';

export function generateStaticParams() {
  return locales.map((locale) => ({ locale }));
}

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}): Promise<Metadata> {
  const { locale } = await params;
  if (!isLocale(locale)) return {};
  const dict = await getDictionary(locale);
  return {
    title: dict.meta.title,
    description: dict.meta.description,
    alternates: {
      canonical: `/${locale}`,
      // 'pcm' (Nigerian Pidgin) is valid hreflang but not in Next's Locale union type.
      languages: { en: '/en', pcm: '/pcm', 'x-default': '/en' } as Record<string, string>,
    },
  };
}

export default async function LocaleLayout({
  children,
  params,
}: {
  children: ReactNode;
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  if (!isLocale(locale)) notFound();

  return (
    <html lang={locale} className={`${bodyFont.variable} ${displayFont.variable}`}>
      <body className="bg-surface-background font-sans text-body-large text-ink-primary antialiased dark:bg-surface-dark-background dark:text-ink-dark-primary">
        {children}
      </body>
    </html>
  );
}
