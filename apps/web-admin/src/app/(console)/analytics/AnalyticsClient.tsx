'use client';

// Analytics console: metric + country selectors, a 30-day SVG series, and
// the read-only AI Admin Assistant. All five wire metrics are exposed;
// jobs_completed and offer_acceptance_rate use the dict's requests /
// conversion labels, the rest map by name.

import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { useQuery } from '@tanstack/react-query';
import { dict } from '@/lib/i18n';
import { analyticsRepository } from '@/mocks/repositories';
import type { AnalyticsMetric } from '@/mocks/types';
import { StateBlock } from '@/components/StateBlock';
import { errorText, isSessionError } from '../_shared';
import { AiAssistant } from './AiAssistant';
import { LineChart } from './LineChart';

const METRICS: { key: keyof typeof dict.analytics.metrics; wire: AnalyticsMetric }[] = [
  { key: 'gmv', wire: 'gmv' },
  { key: 'requests', wire: 'jobs_completed' },
  { key: 'dau', wire: 'dau' },
  { key: 'conversion', wire: 'offer_acceptance_rate' },
  { key: 'dispute_rate', wire: 'dispute_rate' },
];

// Only NG/KE/GH have seeded series; the mock throws ERR_UNKNOWN otherwise.
const COUNTRIES = ['NG', 'KE', 'GH'] as const;

const chipBase =
  'rounded-pill px-lg py-sm text-label-large transition-colors duration-normal ease-standard';
const chipOn = 'bg-brand-primary text-brand-on-primary';
const chipOff =
  'border border-outline text-ink-primary hover:bg-surface-muted dark:border-outline-dark dark:text-ink-dark-primary dark:hover:bg-surface-dark-muted';

export function AnalyticsClient() {
  const router = useRouter();
  const [metric, setMetric] = useState<(typeof METRICS)[number]>(METRICS[0]);
  const [country, setCountry] = useState<(typeof COUNTRIES)[number]>('NG');

  const seriesQuery = useQuery({
    queryKey: ['analytics', 'series', metric.wire, country],
    queryFn: () => analyticsRepository.getSeries(metric.wire, country),
    retry: false,
  });

  useEffect(() => {
    if (seriesQuery.error && isSessionError(seriesQuery.error)) {
      router.replace('/sign-in');
    }
  }, [seriesQuery.error, router]);

  const countryNames = dict.dashboard.countries as Record<string, string>;

  return (
    <div className="flex flex-col gap-xl">
      <h1 className="text-headline-medium text-ink-primary dark:text-ink-dark-primary">
        {dict.analytics.title}
      </h1>

      <div className="flex flex-col gap-md">
        <div className="flex flex-wrap gap-sm" role="group" aria-label={dict.analytics.title}>
          {METRICS.map((m) => (
            <button
              key={m.key}
              type="button"
              aria-pressed={metric.key === m.key}
              onClick={() => setMetric(m)}
              className={`${chipBase} ${metric.key === m.key ? chipOn : chipOff}`}
            >
              {dict.analytics.metrics[m.key]}
            </button>
          ))}
        </div>
        <div className="flex flex-wrap gap-sm" role="group" aria-label={dict.directory.columns.country}>
          {COUNTRIES.map((c) => (
            <button
              key={c}
              type="button"
              aria-pressed={country === c}
              onClick={() => setCountry(c)}
              className={`${chipBase} ${country === c ? chipOn : chipOff}`}
            >
              {countryNames[c] ?? c}
            </button>
          ))}
        </div>
      </div>

      <section className="flex flex-col gap-md">
        <p className="text-body-small text-ink-secondary dark:text-ink-dark-secondary">
          {dict.analytics.seriesNote}
        </p>
        {seriesQuery.isPending ? (
          <StateBlock variant="loading" />
        ) : seriesQuery.isError ? (
          <StateBlock
            variant="error"
            errorMessage={errorText(seriesQuery.error)}
            retryLabel={dict.common.retry}
            onRetry={() => void seriesQuery.refetch()}
          />
        ) : seriesQuery.data.points.length === 0 ? (
          <StateBlock variant="empty" emptyTitle={dict.common.emptyGeneric} />
        ) : (
          <LineChart
            points={seriesQuery.data.points}
            label={`${dict.analytics.metrics[metric.key]} — ${countryNames[country] ?? country}`}
          />
        )}
      </section>

      <AiAssistant />
    </div>
  );
}
