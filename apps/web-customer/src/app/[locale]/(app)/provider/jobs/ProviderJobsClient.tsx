'use client';

import Link from 'next/link';
import { useEffect, useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import type { Dictionary } from '@/lib/i18n/en';
import type { Locale } from '@/lib/i18n';
import { catalogRepository, providerRepository } from '@/lib/repositories';
import type { JobRequest, ServiceCategory } from '@/mocks/types';
import { MoneyText } from '@/components/MoneyText';
import { StateBlock } from '@/components/StateBlock';
import { StatusChip } from '@/components/StatusChip';
import {
  ProviderPage,
  card,
  categoryLabel,
  errorText,
  formatDateTime,
  mutedText,
  pageTitle,
  sectionTitle,
  statusLabel,
  statusTone,
} from '../_shared';

function JobCard({
  job,
  locale,
  dict,
  categories,
}: {
  job: JobRequest;
  locale: Locale;
  dict: Dictionary;
  categories: ServiceCategory[];
}) {
  const next = (dict.provider.jobs.next as Record<string, string>)[job.status];
  return (
    <Link
      href={`/${locale}/provider/jobs/${job.id}`}
      data-testid={`provider-job-${job.id}`}
      className={`${card} block transition-colors hover:border-brand-primary dark:hover:border-brand-secondary`}
    >
      <div className="flex flex-wrap items-center justify-between gap-sm">
        <span className="text-label-large text-ink-secondary dark:text-ink-dark-secondary">
          {categoryLabel(dict, categories, job.categoryId)}
        </span>
        <StatusChip label={statusLabel(dict, job.status)} tone={statusTone(job.status)} />
      </div>
      <p className="mt-sm text-body-large text-ink-primary dark:text-ink-dark-primary">{job.description}</p>
      <div className="mt-sm flex flex-wrap gap-md text-body-small text-ink-secondary dark:text-ink-dark-secondary">
        <span>{job.pickup.label}</span>
        {job.agreedPrice ? <MoneyText amountMinor={job.agreedPrice.amountMinor} currency={job.agreedPrice.currency} /> : null}
        <span>{formatDateTime(job.createdAt)}</span>
      </div>
      {next ? <p className="mt-sm text-label-large text-brand-primary dark:text-brand-secondary">{next}</p> : null}
    </Link>
  );
}

export function ProviderJobsClient({ locale, dict }: { locale: Locale; dict: Dictionary }) {
  const t = dict.provider.jobs;
  const [active, setActive] = useState<JobRequest[] | undefined>(undefined);
  const categories = useQuery({ queryKey: ['catalog', 'categories'], queryFn: () => catalogRepository.getCategories() });
  const history = useQuery({ queryKey: ['provider', 'jobs', 'history'], queryFn: () => providerRepository.getMyJobsHistory() });

  useEffect(() => providerRepository.watchMyJobs(setActive), []);

  return (
    <ProviderPage locale={locale} dict={dict}>
      <h1 className={pageTitle}>{t.title}</h1>
      {active === undefined ? (
        <StateBlock variant="loading" />
      ) : active.length === 0 ? (
        <StateBlock variant="empty" emptyTitle={t.empty} />
      ) : (
        <ul className="flex flex-col gap-md" data-testid="provider-active-jobs">
          {active.map((job) => (
            <li key={job.id}>
              <JobCard job={job} locale={locale} dict={dict} categories={categories.data ?? []} />
            </li>
          ))}
        </ul>
      )}

      <section className="flex flex-col gap-md">
        <h2 className={sectionTitle}>{t.history}</h2>
        {history.isPending ? (
          <StateBlock variant="loading" />
        ) : history.isError ? (
          <StateBlock
            variant="error"
            errorMessage={errorText(dict, history.error)}
            retryLabel={dict.common.retry}
            onRetry={() => void history.refetch()}
          />
        ) : history.data.length === 0 ? (
          <p className={mutedText}>{t.historyEmpty}</p>
        ) : (
          <ul className="flex flex-col gap-md">
            {history.data.map((job) => (
              <li key={job.id}>
                <JobCard job={job} locale={locale} dict={dict} categories={categories.data ?? []} />
              </li>
            ))}
          </ul>
        )}
      </section>
    </ProviderPage>
  );
}
