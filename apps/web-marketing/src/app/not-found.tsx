import './globals.css';
import en from '@/lib/i18n/en';

// Global not-found: the pass-through root layout has no <html>/<body>, so this
// page renders its own using the default (English) dictionary.
export default function NotFound() {
  const dict = en;
  return (
    <html lang="en">
      <body className="bg-surface font-sans text-body-large text-ink-primary antialiased dark:bg-surface-dark dark:text-ink-dark-primary">
        <main className="mx-auto flex min-h-screen w-full max-w-3xl flex-col items-center justify-center px-lg text-center">
          <h1 className="text-headline-medium text-ink-primary dark:text-ink-dark-primary">
            {dict.notFound.title}
          </h1>
          <p className="mt-md text-body-large text-ink-secondary dark:text-ink-dark-secondary">
            {dict.notFound.body}
          </p>
          <a
            href="/en"
            className="mt-xxl rounded-md bg-brand-primary px-xl py-md text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong"
          >
            {dict.notFound.cta}
          </a>
        </main>
      </body>
    </html>
  );
}
