import type { Metadata } from 'next';
import type { ReactNode } from 'react';
import { notFound } from 'next/navigation';
import { getDictionary, isLocale, locales, type Locale } from '@/lib/i18n';
import { SiteHeader } from '@/components/SiteHeader';
import { SiteFooter } from '@/components/SiteFooter';
import '../globals.css';

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
    metadataBase: new URL('https://suskii.example'),
    title: { default: dict.meta.title, template: '%s · Suskii' },
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
  const dict = await getDictionary(locale as Locale);

  return (
    <html lang={locale}>
      <body className="bg-surface font-sans text-body-large text-ink-primary antialiased dark:bg-surface-dark dark:text-ink-dark-primary">
        <SiteHeader locale={locale as Locale} dict={dict} />
        <main>{children}</main>
        <SiteFooter locale={locale as Locale} dict={dict} />
      </body>
    </html>
  );
}
