'use client';

import { useEffect, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { dict } from '@/lib/i18n';
import { newIdempotencyKey } from '@/lib/idempotency';
import { supportRepository } from '@/mocks/repositories';
import type { SupportTicketAdmin } from '@/mocks/types';
import { DataTable, type Column } from '@/components/DataTable';
import { FilterBar } from '@/components/FilterBar';
import { StateBlock } from '@/components/StateBlock';
import { StatusChip } from '@/components/StatusChip';
import { can, errorText, formatDateTime, isSessionError, useAdminSession } from '../_shared';

type TicketStatus = SupportTicketAdmin['status'];

export function ticketStatusChip(status: TicketStatus) {
  const label = dict.support.statuses[status];
  const tone =
    status === 'closed'
      ? 'neutral'
      : status === 'assigned'
        ? 'info'
        : 'warning';
  return <StatusChip label={label} tone={tone} />;
}

/** Last activity on a ticket (latest message, else creation). */
export function ticketUpdatedAt(ticket: SupportTicketAdmin): Date {
  return ticket.messages[ticket.messages.length - 1]?.at ?? ticket.createdAt;
}

const STATUS_FILTERS: (TicketStatus | 'all')[] = ['all', 'open', 'assigned', 'closed'];

export function SupportClient() {
  const router = useRouter();
  const queryClient = useQueryClient();
  const sessionQuery = useAdminSession();
  const role = sessionQuery.data?.admin.role;
  const mayRead = role !== undefined && can(role, 'support.read');
  const mayManage = role !== undefined && can(role, 'support.manage');

  const [search, setSearch] = useState('');
  const [status, setStatus] = useState<TicketStatus | 'all'>('all');
  const [assignError, setAssignError] = useState<string | null>(null);
  // One key per assign intent; kept for retries, deleted after success.
  const assignKeys = useRef<Record<string, string>>({});

  const ticketsQuery = useQuery({
    queryKey: ['support', 'list', status],
    queryFn: () => supportRepository.listTickets(status === 'all' ? undefined : status),
    enabled: mayRead,
  });

  useEffect(() => {
    if (ticketsQuery.error && isSessionError(ticketsQuery.error)) router.replace('/sign-in');
  }, [ticketsQuery.error, router]);

  const assign = async (ticketId: string) => {
    const key = (assignKeys.current[ticketId] ??= newIdempotencyKey());
    setAssignError(null);
    try {
      await supportRepository.assignTicket(ticketId, key);
      delete assignKeys.current[ticketId];
      void queryClient.invalidateQueries({ queryKey: ['support'] });
    } catch (e) {
      if (isSessionError(e)) {
        router.replace('/sign-in');
      } else {
        setAssignError(errorText(e));
      }
    }
  };

  const term = search.trim().toLowerCase();
  const rows = (ticketsQuery.data ?? []).filter(
    (t) =>
      term === '' ||
      t.id.toLowerCase().includes(term) ||
      t.subject.toLowerCase().includes(term) ||
      t.userName.toLowerCase().includes(term),
  );

  const columns: Column<SupportTicketAdmin>[] = [
    { key: 'id', label: dict.support.columns.id, render: (t) => t.id },
    { key: 'user', label: dict.support.columns.user, render: (t) => t.userName },
    { key: 'subject', label: dict.support.columns.subject, render: (t) => t.subject },
    {
      key: 'status',
      label: dict.support.columns.status,
      render: (t) => ticketStatusChip(t.status),
    },
    {
      key: 'assigned',
      label: dict.support.columns.assigned,
      render: (t) => t.assignedToAdminId ?? dict.support.unassigned,
    },
    {
      key: 'updated',
      label: dict.support.columns.updated,
      render: (t) => formatDateTime(ticketUpdatedAt(t)),
    },
    {
      key: 'actions',
      label: dict.common.actions,
      render: (t) =>
        mayManage && t.status !== 'closed' ? (
          <button
            type="button"
            onClick={(e) => {
              e.stopPropagation();
              void assign(t.id);
            }}
            className="rounded-md border border-outline px-md py-xs text-label-large text-ink-primary transition-colors duration-normal ease-standard hover:bg-surface-muted dark:border-outline-dark dark:text-ink-dark-primary dark:hover:bg-surface-dark-muted"
          >
            {dict.support.assignToMeCta}
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
        {dict.support.title}
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
            {s === 'all' ? dict.common.all : dict.support.statuses[s]}
          </button>
        ))}
      </FilterBar>

      {assignError ? (
        <p role="alert" className="text-body-small text-error dark:text-error-dark">
          {assignError}
        </p>
      ) : null}

      {ticketsQuery.isPending ? (
        <StateBlock variant="loading" />
      ) : ticketsQuery.isError ? (
        <StateBlock
          variant="error"
          errorMessage={errorText(ticketsQuery.error)}
          retryLabel={dict.common.retry}
          onRetry={() => void ticketsQuery.refetch()}
        />
      ) : (
        <DataTable
          columns={columns}
          rows={rows}
          keyOf={(t) => t.id}
          emptyTitle={dict.common.emptyGeneric}
          onRowClick={(t) => router.push(`/support/${t.id}`)}
        />
      )}
    </div>
  );
}
