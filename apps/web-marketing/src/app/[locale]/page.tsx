import Link from 'next/link';
import type { Metadata } from 'next';
import { getDictionary, isLocale, type Locale } from '@/lib/i18n';
import { Hero } from '@/components/Hero';
import { FeatureGrid } from '@/components/FeatureGrid';
import { Container } from '@/components/Container';
import { StoreBadges } from '@/components/StoreBadges';

type Props = { params: Promise<{ locale: string }> };

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const { locale } = await params;
  if (!isLocale(locale)) return {};
  const dict = await getDictionary(locale);
  return { title: dict.meta.title, description: dict.meta.description };
}

function Strip({
  title,
  body,
  cta,
  href,
}: {
  title: string;
  body: string;
  cta: string;
  href: string;
}) {
  return (
    <section className="bg-surface-muted dark:bg-surface-dark-muted">
      <Container className="flex flex-col items-start gap-lg py-xxxl md:flex-row md:items-center md:justify-between">
        <div className="max-w-2xl">
          <h2 className="text-headline-small text-ink-primary dark:text-ink-dark-primary">{title}</h2>
          <p className="mt-md text-body-large text-ink-secondary dark:text-ink-dark-secondary">
            {body}
          </p>
        </div>
        <Link
          href={href}
          className="shrink-0 rounded-md bg-brand-primary px-xl py-md text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong"
        >
          {cta}
        </Link>
      </Container>
    </section>
  );
}

export default async function HomePage({ params }: Props) {
  const { locale } = await params;
  const dict = await getDictionary(locale as Locale);
  const base = `/${locale}`;

  return (
    <>
      <Hero
        title={dict.home.heroTitle}
        subtitle={dict.home.heroSubtitle}
        primaryCta={{ href: '#download', label: dict.home.heroPrimaryCta }}
        secondaryCta={{ href: `${base}/how-it-works`, label: dict.home.heroSecondaryCta }}
      />
      <FeatureGrid title={dict.home.howTitle} items={dict.home.howTeaser} />
      <Strip
        title={dict.home.servicesTitle}
        body={dict.home.servicesBody}
        cta={dict.home.servicesCta}
        href={`${base}/services`}
      />
      <Strip
        title={dict.home.safetyTitle}
        body={dict.home.safetyBody}
        cta={dict.home.safetyCta}
        href={`${base}/safety`}
      />
      <Strip
        title={dict.home.referralTitle}
        body={dict.home.referralBody}
        cta={dict.home.referralCta}
        href={`${base}/referrals`}
      />
      <Strip
        title={dict.home.providerTitle}
        body={dict.home.providerBody}
        cta={dict.home.providerCta}
        href={`${base}/become-a-provider`}
      />
      <section id="download" className="bg-surface dark:bg-surface-dark">
        <Container className="py-xxxl text-center">
          <h2 className="text-headline-small text-ink-primary dark:text-ink-dark-primary">
            {dict.common.downloadApp}
          </h2>
          <div className="mt-xxl">
            <StoreBadges
              appStoreLabel={dict.common.appStore}
              googlePlayLabel={dict.common.googlePlay}
              downloadLabel={dict.common.downloadApp}
            />
          </div>
        </Container>
      </section>
    </>
  );
}
