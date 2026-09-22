import type { Metadata } from 'next';
import { getDictionary, isLocale, type Locale } from '@/lib/i18n';
import { FaqAccordion } from '@/components/FaqAccordion';
import { Container } from '@/components/Container';

type Props = { params: Promise<{ locale: string }> };

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const { locale } = await params;
  if (!isLocale(locale)) return {};
  const dict = await getDictionary(locale);
  return { title: dict.faq.title };
}

export default async function FaqPage({ params }: Props) {
  const { locale } = await params;
  const dict = await getDictionary(locale as Locale);

  return (
    <>
      <Container className="py-xxxl text-center">
        <h1 className="text-display-small text-ink-primary dark:text-ink-dark-primary">
          {dict.faq.title}
        </h1>
      </Container>
      <FaqAccordion items={dict.faq.items} />
    </>
  );
}
