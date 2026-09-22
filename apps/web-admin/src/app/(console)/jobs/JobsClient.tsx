'use client';

import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { useQuery } from '@tanstack/react-query';
import { dict } from '@/lib/i18n';
import { jobsRepository } from '@/mocks/repositories';
import type { JobAdminView } from '@/mocks/types';
import { DataTable, type Column } from '@/components/DataTable';
import { FilterBar } from '@/components/FilterBar';
import { MoneyText } from '@/components/MoneyText';
import { StateBlock } from '@/components/StateBlock';
import { can, errorText, formatDateTime, isSessionError, useAdminSession } from '../_shared';
import { categoryLabel, jobStatusChip, jobUpdatedAt } from './_shared';

export function JobsClient() {
  const router = useRouter();
  const sessionQuery = useAdminSession();
  const role = sessionQuery.data?.admin.role;
  const mayRead = role !== undefined && can(role, 'jobs.read');

  const [search, setSearch] = useState('');

  const jobsQuery = useQuery({
    queryKey: ['jobs', 'search', search],
    queryFn: () => jobsRepository.searchJobs({ text: search.trim() || undefined }),
    enabled: mayRead,
  });

  useEffect(() => {
    if (jobsQuery.error && isSessionError(jobsQuery.error)) router.replace('/sign-in');
  }, [jobsQuery.error, router]);

  const columns: Column<JobAdminView>[] = [
    {
      key: 'id',
      label: dict.jobs.columns.id,
      render: (job) => (
        <span>
          <span className="block text-label-large">{job.id}</span>
          <span className="block text-body-small text-ink-secondary dark:text-ink-dark-secondary">
            {job.title}
          </span>
        </span>
      ),
    },
    {
      key: 'category',
      label: dict.jobs.columns.category,
      render: (job) => categoryLabel(job.categoryId),
    },
    { key: 'customer', label: dict.jobs.columns.customer, render: (job) => job.customerName },
    {
      key: 'provider',
      label: dict.jobs.columns.provider,
      render: (job) => job.providerName ?? '—',
    },
    { key: 'status', label: dict.jobs.columns.status, render: (job) => jobStatusChip(job.status) },
    {
      key: 'agreedAmount',
      label: dict.jobs.columns.agreedAmount,
      render: (job) =>
        job.agreedPrice ? (
          <MoneyText
            amountMinor={job.agreedPrice.amountMinor}
            currency={job.agreedPrice.currency}
          />
        ) : (
          '—'
        ),
    },
    {
      key: 'updated',
      label: dict.jobs.columns.updated,
      render: (job) => formatDateTime(jobUpdatedAt(job)),
    },
  ];

  if (sessionQuery.isPending) {
    return <StateBlock variant="loading" />;
  }
  if (!mayRead) {
    // Defense in depth: the nav hides this module, and the repo re-checks.
    return <StateBlock variant="error" errorMessage={dict.errors.ERR_PERMISSION_DENIED} />;
  }

  return (
    <div className="flex flex-col gap-xl">
      <h1 className="text-headline-medium text-ink-primary dark:text-ink-dark-primary">
        {dict.jobs.title}
      </h1>

      <FilterBar
        searchLabel={dict.common.search}
        searchPlaceholder={dict.jobs.searchPlaceholder}
        searchValue={search}
        onSearchChange={setSearch}
      />

      {jobsQuery.isPending ? (
        <StateBlock variant="loading" />
      ) : jobsQuery.isError ? (
        <StateBlock
          variant="error"
          errorMessage={errorText(jobsQuery.error)}
          retryLabel={dict.common.retry}
          onRetry={() => void jobsQuery.refetch()}
        />
      ) : (
        <DataTable
          columns={columns}
          rows={jobsQuery.data}
          keyOf={(job) => job.id}
          emptyTitle={dict.common.emptyGeneric}
          onRowClick={(job) => router.push(`/jobs/${job.id}`)}
        />
      )}
    </div>
  );
}
