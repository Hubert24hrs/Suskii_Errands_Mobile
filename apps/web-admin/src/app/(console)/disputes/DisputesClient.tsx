'use client';

import { useEffect, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { dict } from '@/lib/i18n';
import { newIdempotencyKey } from '@/lib/idempotency';
import { disputeRepository } from '@/mocks/repositories';
import type { DisputeCase, DisputeCaseStatus } from '@/mocks/types';
import { DataTable, type Column } from '@/components/DataTable';
import { FilterBar } from '@/components/FilterBar';
import { StateBlock } from '@/components/StateBlock';
import { can, errorText, isSessionError, useAdminSession } from '../_shared';
import { ageDays, disputeReasonLabel, disputeStatusChip } from './_shared';

const STATUS_FILTERS: (DisputeCaseStatus | 'all')[] = [
  'all',
  'open',
  'in_review',
  'resolved',
  'rejected',
];

export function DisputesClient() {
  const router = useRouter();
  const queryClient = useQueryClient();
  const sessionQuery = useAdminSession();
  const role = sessionQuery.data?.admin.role;
  const mayRead = role !== undefined && can(role, 'disputes.read');
  const mayResolve = role !== undefined && can(role, 'disputes.resolve');

  const [search, setSearch] = useState('');
  const [status, setStatus] = useState<DisputeCaseStatus | 'all'>('all');
  const [assignError, setAssignError] = useState<string | null>(null);
  // One key per assign intent; kept for retries, deleted after success.
  const assignKeys = useRef<Record<string, string>>({});

  const disputesQuery = useQuery({
    queryKey: ['disputes', 'list', status],
    queryFn: () => disputeRepository.listDisputes(status === 'all' ? undefined : status),
    enabled: mayRead,
  });

  useEffect(() => {
    if (disputesQuery.error && isSessionError(disputesQuery.error)) router.replace('/sign-in');
  }, [disputesQuery.error, router]);

  const assign = async (disputeId: string) => {
    const key = (assignKeys.current[disputeId] ??= newIdempotencyKey());
    setAssignError(null);
    try {
      await disputeRepository.assignDispute(disputeId, key);
      delete assignKeys.current[disputeId];
      void queryClient.invalidateQueries({ queryKey: ['disputes'] });
    } catch (e) {
      if (isSessionError(e)) {
        router.replace('/sign-in');
      } else {
        setAssignError(errorText(e));
      }
    }
  };

  const term = search.trim().toLowerCase();
  const rows = (disputesQuery.data ?? []).filter(
    (d) =>
      term === '' ||
      d.id.toLowerCase().includes(term) ||
      d.jobId.toLowerCase().includes(term) ||
      d.customerName.toLowerCase().includes(term) ||
      d.providerName.toLowerCase().includes(term),
  );

  const columns: Column<DisputeCase>[] = [
    { key: 'id', label: dict.disputes.columns.id, render: (d) => d.id },
    { key: 'job', label: dict.disputes.columns.job, render: (d) => d.jobId },
    {
      key: 'openedBy',
      label: dict.disputes.columns.openedBy,
      render: (d) => d.customerName,
    },
    {
      key: 'reason',
      label: dict.disputes.columns.reason,
      render: (d) => disputeReasonLabel(d.reasonKey),
    },
    {
      key: 'status',
      label: dict.disputes.columns.status,
      render: (d) => disputeStatusChip(d.status),
    },
    { key: 'age', label: dict.disputes.columns.age, render: (d) => ageDays(d.openedAt) },
    {
      key: 'actions',
      label: dict.common.actions,
      render: (d) =>
        mayResolve && d.status === 'open' ? (
          <button
            type="button"
            onClick={(e) => {
              e.stopPropagation();
              void assign(d.id);
            }}
            className="rounded-md border border-outline px-md py-xs text-label-large text-ink-primary transition-colors duration-normal ease-standard hover:bg-surface-muted dark:border-outline-dark dark:text-ink-dark-primary dark:hover:bg-surface-dark-muted"
          >
            {dict.disputes.detail.assignToMeCta}
          </button>
        ) : null,
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
        {dict.disputes.title}
      </h1>

      <FilterBar
        searchLabel={dict.common.search}
        searchValue={search}
        onSearchChange={setSearch}
      >
        {STATUS_FILTERS.map((s) => (
          <button
            key={s}
            type="button"
            onClick={() => setStatus(s)}
            aria-pressed={status === s}
            className={`rounded-pill px-md py-xs text-label-large transition-colors duration-normal ease-standard ${
              status === s
                ? 'bg-brand-primary text-brand-on-primary'
                : 'border border-outline text-ink-secondary hover:bg-surface-muted dark:border-outline-dark dark:text-ink-dark-secondary dark:hover:bg-surface-dark-muted'
            }`}
          >
            {s === 'all'
              ? dict.common.all
              : ((dict.disputes.statuses as Record<string, string>)[s] ?? s)}
          </button>
        ))}
      </FilterBar>

      {assignError ? (
        <p role="alert" className="text-body-small text-error dark:text-error-dark">
          {assignError}
        </p>
      ) : null}

      {disputesQuery.isPending ? (
        <StateBlock variant="loading" />
      ) : disputesQuery.isError ? (
        <StateBlock
          variant="error"
          errorMessage={errorText(disputesQuery.error)}
          retryLabel={dict.common.retry}
          onRetry={() => void disputesQuery.refetch()}
        />
      ) : (
        <DataTable
          columns={columns}
          rows={rows}
          keyOf={(d) => d.id}
          emptyTitle={dict.common.emptyGeneric}
          onRowClick={(d) => router.push(`/disputes/${d.id}`)}
        />
      )}
    </div>
  );
}
