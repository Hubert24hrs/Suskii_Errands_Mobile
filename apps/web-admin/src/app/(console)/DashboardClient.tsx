'use client';

import { useEffect, useState } from 'react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { useQuery } from '@tanstack/react-query';
import { dict } from '@/lib/i18n';
import { metricsRepository } from '@/mocks/repositories';
import type { CountryMetrics } from '@/mocks/types';
import { KpiCard } from '@/components/KpiCard';
import { StateBlock } from '@/components/StateBlock';
import { formatMoney } from '@/components/MoneyText';
import { errorText, isSessionError } from './_shared';

function countryName(code: string): string {
  const table = dict.dashboard.countries as Record<string, string>;
  return table[code] ?? code;
}

function KpiGrid({ metrics }: { metrics: CountryMetrics }) {
  // CountryMetrics carries no trend delta — omitted until the API grows one.
  const cards: { label: string; value: string; href: string }[] = [
    {
      label: dict.dashboard.metrics.activeUsers,
      value: metrics.dau.toLocaleString('en-GB'),
      href: '/directory',
    },
    {
      label: dict.dashboard.metrics.activeJobs,
      value: metrics.activeJobs.toLocaleString('en-GB'),
      href: '/jobs',
    },
    {
      label: dict.dashboard.metrics.gmv,
      value: formatMoney(metrics.gmv.amountMinor, metrics.gmv.currency),
      href: '/payments',
    },
    {
      label: dict.dashboard.metrics.fundsHeld,
      value: formatMoney(metrics.holdBalance.amountMinor, metrics.holdBalance.currency),
      href: '/payments',
    },
    {
      label: dict.dashboard.metrics.openDisputes,
      value: String(metrics.openDisputes),
      href: '/disputes',
    },
    {
      label: dict.dashboard.metrics.openSos,
      value: String(metrics.openSos),
      href: '/sos',
    },
  ];

  return (
    <div className="grid gap-lg sm:grid-cols-2 xl:grid-cols-3">
      {cards.map((card) => (
        <Link key={card.label} href={card.href} className="block">
          <KpiCard
            label={card.label}
            value={card.value}
            tone={
              card.label === dict.dashboard.metrics.openSos && metrics.openSos > 0
                ? 'error'
                : 'neutral'
            }
          />
        </Link>
      ))}
    </div>
  );
}

export function DashboardClient() {
  const router = useRouter();
  const [country, setCountry] = useState<string>('all');
  const query = useQuery({
    queryKey: ['metrics', 'overview'],
    queryFn: () => metricsRepository.getOverview(),
  });

  useEffect(() => {
    if (query.error && isSessionError(query.error)) router.replace('/sign-in');
  }, [query.error, router]);

  const all = query.data;
  const selected =
    country === 'all' ? undefined : all?.find((m) => m.country === country);

  return (
    <div className="flex flex-col gap-xxl">
      <h1 className="text-headline-medium text-ink-primary dark:text-ink-dark-primary">
        {dict.dashboard.title}
      </h1>

      <div className="flex flex-wrap gap-sm" role="tablist" aria-label={dict.dashboard.title}>
        <button
          type="button"
          role="tab"
          aria-selected={country === 'all'}
          onClick={() => setCountry('all')}
          className={`rounded-pill px-lg py-sm text-label-large transition-colors duration-normal ease-standard ${
            country === 'all'
              ? 'bg-brand-primary text-brand-on-primary'
              : 'border border-outline text-ink-primary hover:bg-surface-muted dark:border-outline-dark dark:text-ink-dark-primary dark:hover:bg-surface-dark-muted'
          }`}
        >
          {dict.dashboard.countries.all}
        </button>
        {(all ?? []).map((m) => (
          <button
            key={m.country}
            type="button"
            role="tab"
            aria-selected={country === m.country}
            onClick={() => setCountry(m.country)}
            className={`rounded-pill px-lg py-sm text-label-large transition-colors duration-normal ease-standard ${
              country === m.country
                ? 'bg-brand-primary text-brand-on-primary'
                : 'border border-outline text-ink-primary hover:bg-surface-muted dark:border-outline-dark dark:text-ink-dark-primary dark:hover:bg-surface-dark-muted'
            }`}
          >
            {countryName(m.country)}
          </button>
        ))}
      </div>

      {query.isPending ? (
        <StateBlock variant="loading" />
      ) : query.isError ? (
        <StateBlock
          variant="error"
          errorMessage={errorText(query.error)}
          retryLabel={dict.common.retry}
          onRetry={() => void query.refetch()}
        />
      ) : !all || all.length === 0 ? (
        <StateBlock variant="empty" emptyTitle={dict.common.emptyGeneric} />
      ) : selected ? (
        <KpiGrid metrics={selected} />
      ) : (
        // "All countries": one KPI grid per country — money is never summed
        // across currencies.
        <div className="flex flex-col gap-xxl">
          {all.map((m) => (
            <section key={m.country}>
              <h2 className="mb-lg text-title-large text-ink-primary dark:text-ink-dark-primary">
                {countryName(m.country)}
              </h2>
              <KpiGrid metrics={m} />
            </section>
          ))}
        </div>
      )}
    </div>
  );
}
