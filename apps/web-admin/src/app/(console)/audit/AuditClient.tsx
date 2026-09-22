'use client';

// Append-only audit log (super admin only — the mock enforces audit.read).
// Read-only page: listEntries gives the newest-first list, watchEntries
// invalidates the query when a mutation anywhere in the console appends an
// entry. Actor/action filters are client-side text filters over the list.

import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { dict } from '@/lib/i18n';
import { auditRepository } from '@/mocks/repositories';
import type { AuditLogEntry } from '@/mocks/types';
import { DataTable, type Column } from '@/components/DataTable';
import { FilterBar } from '@/components/FilterBar';
import { StateBlock } from '@/components/StateBlock';
import { errorText, formatDateTime, isSessionError } from '../_shared';

const actionFilterClasses =
  'rounded-md border border-outline bg-surface-raised px-md py-sm text-body-large text-ink-primary outline-none transition-colors duration-normal ease-standard placeholder:text-ink-secondary focus:border-brand-primary dark:border-outline-dark dark:bg-surface-dark-raised dark:text-ink-dark-primary dark:placeholder:text-ink-dark-secondary';

export function AuditClient() {
  const router = useRouter();
  const queryClient = useQueryClient();
  const [actorFilter, setActorFilter] = useState('');
  const [actionFilter, setActionFilter] = useState('');

  const entriesQuery = useQuery({
    queryKey: ['audit', 'entries'],
    queryFn: () => auditRepository.listEntries(),
    retry: false,
  });

  // Live tail: any mutation in the console appends an entry server-side.
  useEffect(() => {
    let unsubscribe: (() => void) | undefined;
    try {
      unsubscribe = auditRepository.watchEntries(() => {
        void queryClient.invalidateQueries({ queryKey: ['audit'] });
      });
    } catch {
      // No audit.read permission — the list query surfaces the error state.
    }
    return () => unsubscribe?.();
  }, [queryClient]);

  useEffect(() => {
    if (entriesQuery.error && isSessionError(entriesQuery.error)) {
      router.replace('/sign-in');
    }
  }, [entriesQuery.error, router]);

  if (entriesQuery.isPending) {
    return <StateBlock variant="loading" />;
  }
  if (entriesQuery.isError) {
    return (
      <StateBlock
        variant="error"
        errorMessage={errorText(entriesQuery.error)}
        retryLabel={dict.common.retry}
        onRetry={() => void entriesQuery.refetch()}
      />
    );
  }

  const actorText = actorFilter.trim().toLowerCase();
  const actionText = actionFilter.trim().toLowerCase();
  const rows = entriesQuery.data.filter((entry) => {
    if (
      actorText !== '' &&
      !entry.actorName.toLowerCase().includes(actorText) &&
      !entry.actorAdminId.toLowerCase().includes(actorText)
    ) {
      return false;
    }
    if (actionText !== '' && !entry.action.toLowerCase().startsWith(actionText)) {
      return false;
    }
    return true;
  });

  const columns: Column<AuditLogEntry>[] = [
    {
      key: 'time',
      label: dict.audit.columns.time,
      render: (entry) => formatDateTime(entry.at),
    },
    {
      key: 'actor',
      label: dict.audit.columns.actor,
      render: (entry) => (
        <div className="flex flex-col gap-xxs">
          <span>{entry.actorName}</span>
          <span className="text-body-small text-ink-secondary dark:text-ink-dark-secondary">
            {entry.actorAdminId}
          </span>
        </div>
      ),
    },
    { key: 'action', label: dict.audit.columns.action },
    { key: 'target', label: dict.audit.columns.target },
    {
      key: 'reason',
      label: dict.audit.columns.reason,
      render: (entry) => entry.reason ?? '—',
    },
  ];

  return (
    <div className="flex flex-col gap-xl">
      <h1 className="text-headline-medium text-ink-primary dark:text-ink-dark-primary">
        {dict.audit.title}
      </h1>

      <FilterBar
        searchLabel={dict.audit.filterActorLabel}
        searchValue={actorFilter}
        onSearchChange={setActorFilter}
      >
        <input
          type="search"
          aria-label={dict.audit.filterActionLabel}
          placeholder={dict.audit.filterActionPlaceholder}
          value={actionFilter}
          onChange={(e) => setActionFilter(e.target.value)}
          className={actionFilterClasses}
        />
      </FilterBar>

      <DataTable
        columns={columns}
        rows={rows}
        keyOf={(entry) => entry.id}
        emptyTitle={dict.common.emptyGeneric}
        emptyBody={dict.audit.empty}
      />
    </div>
  );
}
