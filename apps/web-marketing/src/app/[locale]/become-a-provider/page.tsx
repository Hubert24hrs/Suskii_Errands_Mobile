import type { Metadata } from 'next';
import { getDictionary, isLocale, type Locale } from '@/lib/i18n';
import { Container } from '@/components/Container';

type Props = { params: Promise<{ locale: string }> };

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const { locale } = await params;
  if (!isLocale(locale)) return {};
  const dict = await getDictionary(locale);
  return { title: dict.providers.title, description: dict.providers.subtitle };
}

export default async function BecomeAProviderPage({ params }: Props) {
  const { locale } = await params;
  const dict = await getDictionary(locale as Locale);

  return (
    <Container className="max-w-3xl py-xxxl">
      <h1 className="text-display-small text-ink-primary dark:text-ink-dark-primary">
        {dict.providers.title}
      </h1>
      <p className="mt-md text-body-large text-ink-secondary dark:text-ink-dark-secondary">
        {dict.providers.subtitle}
      </p>

      <h2 className="mt-xxxl text-headline-small text-ink-primary dark:text-ink-dark-primary">
        {dict.providers.requirementsTitle}
      </h2>
      <ul className="mt-lg list-disc space-y-sm pl-xl text-body-large text-ink-secondary marker:text-brand-primary dark:text-ink-dark-secondary dark:marker:text-brand-secondary">
        {dict.providers.requirements.map((req) => (
          <li key={req}>{req}</li>
        ))}
      </ul>

      <h2 className="mt-xxxl text-headline-small text-ink-primary dark:text-ink-dark-primary">
        {dict.providers.earningsTitle}
      </h2>
      <p className="mt-lg text-body-large text-ink-secondary dark:text-ink-dark-secondary">
        {dict.providers.earningsBody}
      </p>

      {/* TODO(M7/M9): link to provider onboarding once the app store listings exist */}
      <a
        href="#"
        className="mt-xxxl inline-block rounded-md bg-brand-primary px-xl py-md text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong"
      >
        {dict.providers.cta}
      </a>
    </Container>
  );
}
