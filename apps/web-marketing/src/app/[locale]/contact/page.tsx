import type { Metadata } from 'next';
import { getDictionary, isLocale, type Locale } from '@/lib/i18n';
import { Container } from '@/components/Container';

type Props = { params: Promise<{ locale: string }> };

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const { locale } = await params;
  if (!isLocale(locale)) return {};
  const dict = await getDictionary(locale);
  return { title: dict.contact.title, description: dict.contact.subtitle };
}

export default async function ContactPage({ params }: Props) {
  const { locale } = await params;
  const dict = await getDictionary(locale as Locale);

  return (
    <Container className="max-w-3xl py-xxxl">
      <h1 className="text-display-small text-ink-primary dark:text-ink-dark-primary">
        {dict.contact.title}
      </h1>
      <p className="mt-md text-body-large text-ink-secondary dark:text-ink-dark-secondary">
        {dict.contact.subtitle}
      </p>

      <div className="mt-xxxl space-y-xl">
        <section className="rounded-lg border border-outline bg-surface-raised p-xl dark:border-outline-dark dark:bg-surface-dark-raised">
          <h2 className="text-title-large text-ink-primary dark:text-ink-dark-primary">
            {dict.contact.emailLabel}
          </h2>
          {/* TODO: replace placeholder support address with the real mailbox */}
          <a
            href={`mailto:${dict.contact.emailAddress}`}
            className="mt-sm inline-block text-body-large font-semibold text-brand-primary hover:text-brand-primary-strong dark:text-brand-secondary"
          >
            {dict.contact.emailAddress}
          </a>
        </section>
        <section className="rounded-lg border border-outline bg-surface-raised p-xl dark:border-outline-dark dark:bg-surface-dark-raised">
          <h2 className="text-title-large text-ink-primary dark:text-ink-dark-primary">
            {dict.contact.inAppTitle}
          </h2>
          <p className="mt-sm text-body-large text-ink-secondary dark:text-ink-dark-secondary">
            {dict.contact.inAppBody}
          </p>
        </section>
      </div>
    </Container>
  );
}
