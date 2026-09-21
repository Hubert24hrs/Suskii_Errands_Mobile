import type { Metadata } from 'next';
import { getDictionary, isLocale, type Locale } from '@/lib/i18n';
import { Container } from '@/components/Container';

type Props = { params: Promise<{ locale: string }> };

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const { locale } = await params;
  if (!isLocale(locale)) return {};
  const dict = await getDictionary(locale);
  return { title: dict.services.title, description: dict.services.subtitle };
}

export default async function ServicesPage({ params }: Props) {
  const { locale } = await params;
  const dict = await getDictionary(locale as Locale);

  return (
    <Container className="py-xxxl">
      <h1 className="text-display-small text-ink-primary dark:text-ink-dark-primary">
        {dict.services.title}
      </h1>
      <p className="mt-md max-w-2xl text-body-large text-ink-secondary dark:text-ink-dark-secondary">
        {dict.services.subtitle}
      </p>
      <div className="mt-xxl grid gap-xl sm:grid-cols-2 lg:grid-cols-3">
        {dict.services.categories.map((category) => (
          <article
            key={category.name}
            className="rounded-lg border border-outline bg-surface-raised p-xl dark:border-outline-dark dark:bg-surface-dark-raised"
          >
            <h2 className="text-title-large text-ink-primary dark:text-ink-dark-primary">
              {category.name}
            </h2>
            <p className="mt-sm text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
              {category.blurb}
            </p>
          </article>
        ))}
      </div>
    </Container>
  );
}
