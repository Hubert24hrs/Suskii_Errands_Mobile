import Link from 'next/link';
import type { Dictionary } from '@/lib/i18n/en';
import type { Locale } from '@/lib/i18n';
import { cities } from '@/lib/cities';
import { Container } from './Container';

export function SiteFooter({ locale, dict }: { locale: Locale; dict: Dictionary }) {
  const base = `/${locale}`;
  const explore = [
    { href: `${base}/how-it-works`, label: dict.nav.howItWorks },
    { href: `${base}/services`, label: dict.nav.services },
    { href: `${base}/referrals`, label: dict.nav.referrals },
    { href: `${base}/faq`, label: dict.nav.faq },
  ];
  const company = [
    { href: `${base}/become-a-provider`, label: dict.nav.becomeProvider },
    { href: `${base}/businesses`, label: dict.nav.businesses },
    { href: `${base}/safety`, label: dict.nav.safety },
    { href: `${base}/contact`, label: dict.nav.contact },
  ];

  return (
    <footer className="border-t border-outline bg-surface-muted dark:border-outline-dark dark:bg-surface-dark-muted">
      <Container className="grid gap-xxl py-xxxl md:grid-cols-4">
        <div>
          <p className="text-title-medium text-ink-primary dark:text-ink-dark-primary">Suskii</p>
          <p className="mt-sm text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
            {dict.footer.tagline}
          </p>
        </div>
        <nav aria-label={dict.footer.exploreTitle}>
          <p className="text-label-large text-ink-primary dark:text-ink-dark-primary">
            {dict.footer.exploreTitle}
          </p>
          <ul className="mt-md space-y-sm">
            {explore.map((link) => (
              <li key={link.href}>
                <Link
                  href={link.href}
                  className="text-body-medium text-ink-secondary hover:text-ink-primary dark:text-ink-dark-secondary dark:hover:text-ink-dark-primary"
                >
                  {link.label}
                </Link>
              </li>
            ))}
          </ul>
        </nav>
        <nav aria-label={dict.footer.companyTitle}>
          <p className="text-label-large text-ink-primary dark:text-ink-dark-primary">
            {dict.footer.companyTitle}
          </p>
          <ul className="mt-md space-y-sm">
            {company.map((link) => (
              <li key={link.href}>
                <Link
                  href={link.href}
                  className="text-body-medium text-ink-secondary hover:text-ink-primary dark:text-ink-dark-secondary dark:hover:text-ink-dark-primary"
                >
                  {link.label}
                </Link>
              </li>
            ))}
          </ul>
        </nav>
        <nav aria-label={dict.footer.legalTitle}>
          <p className="text-label-large text-ink-primary dark:text-ink-dark-primary">
            {dict.footer.legalTitle}
          </p>
          <ul className="mt-md space-y-sm">
            <li>
              <Link
                href={`${base}/legal/privacy`}
                className="text-body-medium text-ink-secondary hover:text-ink-primary dark:text-ink-dark-secondary dark:hover:text-ink-dark-primary"
              >
                {dict.footer.privacy}
              </Link>
            </li>
            <li>
              <Link
                href={`${base}/legal/terms`}
                className="text-body-medium text-ink-secondary hover:text-ink-primary dark:text-ink-dark-secondary dark:hover:text-ink-dark-primary"
              >
                {dict.footer.terms}
              </Link>
            </li>
          </ul>
          <p className="mt-lg text-label-large text-ink-primary dark:text-ink-dark-primary">
            {dict.footer.cities}
          </p>
          <ul className="mt-md space-y-sm">
            {cities.map((slug) => (
              <li key={slug}>
                <Link
                  href={`${base}/cities/${slug}`}
                  className="text-body-medium text-ink-secondary hover:text-ink-primary dark:text-ink-dark-secondary dark:hover:text-ink-dark-primary"
                >
                  {dict.city[slug].name}
                </Link>
              </li>
            ))}
          </ul>
        </nav>
      </Container>
      <Container className="border-t border-outline py-lg dark:border-outline-dark">
        <p className="text-body-small text-ink-secondary dark:text-ink-dark-secondary">
          © {new Date().getFullYear()} {dict.footer.rights}
        </p>
      </Container>
    </footer>
  );
}
