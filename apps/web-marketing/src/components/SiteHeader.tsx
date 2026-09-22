import Link from 'next/link';
import type { Dictionary } from '@/lib/i18n/en';
import type { Locale } from '@/lib/i18n';
import { Container } from './Container';
import { LocaleSwitcher } from './LocaleSwitcher';

export function SiteHeader({ locale, dict }: { locale: Locale; dict: Dictionary }) {
  const base = `/${locale}`;
  const links = [
    { href: `${base}/how-it-works`, label: dict.nav.howItWorks },
    { href: `${base}/services`, label: dict.nav.services },
    { href: `${base}/become-a-provider`, label: dict.nav.becomeProvider },
    { href: `${base}/safety`, label: dict.nav.safety },
    { href: `${base}/faq`, label: dict.nav.faq },
  ];

  return (
    <header className="border-b border-outline bg-surface-raised dark:border-outline-dark dark:bg-surface-dark-raised">
      <Container className="flex h-16 items-center justify-between gap-lg">
        <Link
          href={base}
          className="flex items-center gap-sm text-title-large text-ink-primary dark:text-ink-dark-primary"
        >
          <span className="flex h-8 w-8 items-center justify-center rounded-sm bg-brand-primary font-bold text-brand-on-primary">
            S
          </span>
          Suskii
        </Link>
        <nav className="hidden items-center gap-xl md:flex" aria-label={dict.nav.home}>
          {links.map((link) => (
            <Link
              key={link.href}
              href={link.href}
              className="text-body-medium text-ink-secondary transition-colors duration-normal ease-standard hover:text-ink-primary dark:text-ink-dark-secondary dark:hover:text-ink-dark-primary"
            >
              {link.label}
            </Link>
          ))}
        </nav>
        <div className="flex items-center gap-md">
          <LocaleSwitcher locale={locale} />
          <Link
            href={`${base}#download`}
            className="hidden rounded-md bg-brand-primary px-lg py-sm text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong sm:inline-block"
          >
            {dict.nav.getTheApp}
          </Link>
        </div>
      </Container>
    </header>
  );
}
