import Link from 'next/link';
import { Container } from './Container';

export function Hero({
  title,
  subtitle,
  primaryCta,
  secondaryCta,
}: {
  title: string;
  subtitle: string;
  primaryCta: { href: string; label: string };
  secondaryCta: { href: string; label: string };
}) {
  return (
    <section className="bg-surface dark:bg-surface-dark">
      <Container className="py-xxxl text-center md:py-[96px]">
        <h1 className="mx-auto max-w-3xl text-display-small font-bold text-ink-primary dark:text-ink-dark-primary md:text-[48px]">
          {title}
        </h1>
        <p className="mx-auto mt-lg max-w-2xl text-body-large text-ink-secondary dark:text-ink-dark-secondary">
          {subtitle}
        </p>
        <div className="mt-xxl flex flex-wrap justify-center gap-md">
          <Link
            href={primaryCta.href}
            className="rounded-md bg-brand-primary px-xl py-md text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong"
          >
            {primaryCta.label}
          </Link>
          <Link
            href={secondaryCta.href}
            className="rounded-md bg-brand-secondary px-xl py-md text-label-large text-brand-on-secondary transition-colors duration-normal ease-standard hover:opacity-90"
          >
            {secondaryCta.label}
          </Link>
        </div>
      </Container>
    </section>
  );
}
