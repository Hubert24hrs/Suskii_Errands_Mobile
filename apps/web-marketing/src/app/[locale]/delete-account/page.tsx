import type { Metadata } from 'next';
import { getDictionary, isLocale, type Locale } from '@/lib/i18n';
import { FeatureGrid } from '@/components/FeatureGrid';
import { Container } from '@/components/Container';

type Props = { params: Promise<{ locale: string }> };

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const { locale } = await params;
  if (!isLocale(locale)) return {};
  const dict = await getDictionary(locale);
  return { title: dict.deleteAccount.title, description: dict.deleteAccount.subtitle };
}

/**
 * The account-deletion page Google Play's Data safety form links to (RB-15): how to delete
 * from the app and from the web, and what deletion does. The copy follows
 * private.erase_account in supabase/migrations/20260927120000_account_lifecycle.sql.
 */
export default async function DeleteAccountPage({ params }: Props) {
  const { locale } = await params;
  const dict = await getDictionary(locale as Locale);
  const page = dict.deleteAccount;

  return (
    <>
      <Container className="py-xxxl">
        <h1 className="text-display-small text-ink-primary dark:text-ink-dark-primary">
          {page.title}
        </h1>
        <p className="mt-md max-w-2xl text-body-large text-ink-secondary dark:text-ink-dark-secondary">
          {page.subtitle}
        </p>
      </Container>
      <FeatureGrid items={page.steps} columns={3} />
      <Container className="py-xxl">
        <h2 className="text-headline-small text-ink-primary dark:text-ink-dark-primary">
          {page.whatHappensTitle}
        </h2>
        <ul className="mt-md max-w-3xl list-disc space-y-sm pl-lg text-body-large text-ink-secondary dark:text-ink-dark-secondary">
          {page.whatHappens.map((line) => (
            <li key={line}>{line}</li>
          ))}
        </ul>
        <p className="mt-lg max-w-3xl text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
          {page.contact}
        </p>
      </Container>
    </>
  );
}
