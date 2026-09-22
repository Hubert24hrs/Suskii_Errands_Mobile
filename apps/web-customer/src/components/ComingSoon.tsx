import Link from 'next/link';
import type { Dictionary } from '@/lib/i18n/en';

export function ComingSoon({ locale, dict }: { locale: string; dict: Dictionary }) {
  return (
    <div className="mx-auto flex w-full max-w-3xl flex-col items-center px-lg py-xxxl text-center">
      <h1 className="text-headline-medium text-ink-primary dark:text-ink-dark-primary">
        {dict.comingSoon.title}
      </h1>
      <p className="mt-md text-body-large text-ink-secondary dark:text-ink-dark-secondary">
        {dict.comingSoon.body}
      </p>
      <Link
        href={`/${locale}`}
        className="mt-xxl rounded-md bg-brand-primary px-xl py-md text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong"
      >
        {dict.comingSoon.cta}
      </Link>
    </div>
  );
}
