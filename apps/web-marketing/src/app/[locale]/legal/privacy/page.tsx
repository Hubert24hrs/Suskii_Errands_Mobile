import type { Metadata } from 'next';
import { getDictionary, isLocale, type Locale } from '@/lib/i18n';
import { Container } from '@/components/Container';

type Props = { params: Promise<{ locale: string }> };

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const { locale } = await params;
  if (!isLocale(locale)) return {};
  const dict = await getDictionary(locale);
  return { title: dict.legal.privacyTitle };
}

export default async function PrivacyPage({ params }: Props) {
  const { locale } = await params;
  const dict = await getDictionary(locale as Locale);

  return (
    <Container className="max-w-3xl py-xxxl">
      <h1 className="text-display-small text-ink-primary dark:text-ink-dark-primary">
        {dict.legal.privacyTitle}
      </h1>
      <p className="mt-lg inline-block rounded-sm bg-surface-muted px-md py-sm text-body-small font-semibold text-ink-secondary dark:bg-surface-dark-muted dark:text-ink-dark-secondary">
        {dict.legal.placeholderNote}
      </p>
      {dict.legal.privacyBody.map((paragraph) => (
        <p
          key={paragraph.slice(0, 32)}
          className="mt-lg text-body-large text-ink-secondary dark:text-ink-dark-secondary"
        >
          {paragraph}
        </p>
      ))}
    </Container>
  );
}
