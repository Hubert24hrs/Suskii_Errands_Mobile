'use client';

import { useEffect, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { dict } from '@/lib/i18n';
import { newIdempotencyKey } from '@/lib/idempotency';
import { riskRepository } from '@/mocks/repositories';
import type { RiskCase } from '@/mocks/types';
import { DataTable, type Column } from '@/components/DataTable';
import { Drawer } from '@/components/Drawer';
import { StateBlock } from '@/components/StateBlock';
import { StatusChip } from '@/components/StatusChip';
import { can, errorText, formatDateTime, isSessionError, useAdminSession } from '../_shared';

type RiskStatus = RiskCase['status'];

function riskStatusChip(status: RiskStatus) {
  const label = (dict.risk.statuses as Record<string, string>)[status] ?? status;
  const tone =
    status === 'escalated' ? 'error' : status === 'reviewed' ? 'success' : 'warning';
  return <StatusChip label={label} tone={tone} />;
}

/** Kind labels — dict.risk.kinds covers the full RiskCaseKind union. */
function riskKindLabel(kind: RiskCase['kind']): string {
  return dict.risk.kinds[kind];
}

function RiskDetail({
  riskCase,
  mayReview,
  onAction,
}: {
  riskCase: RiskCase;
  mayReview: boolean;
  onAction: (fn: () => Promise<unknown>, onSuccess?: () => void) => void;
}) {
  // One key per (action, case) intent; kept for retries, deleted after success.
  const intentKeys = useRef<Record<string, string>>({});
  const keyFor = (name: string) => (intentKeys.current[name] ??= newIdempotencyKey());

  return (
    <div className="flex flex-col gap-lg">
      <div className="flex flex-wrap items-center gap-md">
        {riskStatusChip(riskCase.status)}
        <span className="text-body-large text-ink-primary dark:text-ink-dark-primary">
          {riskKindLabel(riskCase.kind)}
        </span>
      </div>

      <div className="divide-y divide-outline dark:divide-outline-dark">
        <div className="flex flex-wrap justify-between gap-md py-sm">
          <span className="text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
            {dict.risk.columns.user}
          </span>
          <span className="text-body-medium text-ink-primary dark:text-ink-dark-primary">
            {riskCase.subjectName} · {riskCase.subjectUserId}
          </span>
        </div>
        <div className="flex flex-wrap justify-between gap-md py-sm">
          <span className="text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
            {dict.directory.columns.country}
          </span>
          <span className="text-body-medium text-ink-primary dark:text-ink-dark-primary">
            {(dict.dashboard.countries as Record<string, string>)[riskCase.country] ??
              riskCase.country}
          </span>
        </div>
        <div className="flex flex-wrap justify-between gap-md py-sm">
          <span className="text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
            {dict.audit.columns.time}
          </span>
          <span className="text-body-medium text-ink-primary dark:text-ink-dark-primary">
            {formatDateTime(riskCase.openedAt)}
          </span>
        </div>
        {riskCase.reviewedByAdminId ? (
          <div className="flex flex-wrap justify-between gap-md py-sm">
            <span className="text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
              {dict.risk.markReviewedCta}
            </span>
            <span className="text-body-medium text-ink-primary dark:text-ink-dark-primary">
              {riskCase.reviewedByAdminId}
            </span>
          </div>
        ) : null}
      </div>

      <section className="flex flex-col gap-sm">
        <h3 className="text-title-large text-ink-primary dark:text-ink-dark-primary">
          {dict.risk.columns.signals}
        </h3>
        <ul className="flex list-disc flex-col gap-xs pl-lg text-body-medium text-ink-primary dark:text-ink-dark-primary">
          {riskCase.signals.map((signal) => (
            <li key={signal}>{signal}</li>
          ))}
        </ul>
      </section>

      {mayReview ? (
        <div className="flex flex-wrap gap-md">
          {riskCase.status === 'open' ? (
            <button
              type="button"
              onClick={() =>
                onAction(async () => {
                  const key = keyFor(`review:${riskCase.id}`);
                  await riskRepository.markReviewed(riskCase.id, key);
                  delete intentKeys.current[`review:${riskCase.id}`];
                })
              }
              className="rounded-md bg-brand-primary px-xl py-sm text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong"
            >
              {dict.risk.markReviewedCta}
            </button>
          ) : null}
          {riskCase.status !== 'escalated' ? (
            <button
              type="button"
              onClick={() =>
                onAction(async () => {
                  const key = keyFor(`escalate:${riskCase.id}`);
                  await riskRepository.escalate(riskCase.id, key);
                  delete intentKeys.current[`escalate:${riskCase.id}`];
                })
              }
              className="rounded-md border border-error px-xl py-sm text-label-large text-error transition-colors duration-normal ease-standard hover:bg-error/10 dark:border-error-dark dark:text-error-dark dark:hover:bg-error-dark/20"
            >
              {dict.risk.escalateCta}
            </button>
          ) : null}
        </div>
      ) : null}
    </div>
  );
}

export function RiskClient() {
  const router = useRouter();
  const queryClient = useQueryClient();
  const sessionQuery = useAdminSession();
  const role = sessionQuery.data?.admin.role;
  const mayRead = role !== undefined && can(role, 'risk.read');
  const mayReview = role !== undefined && can(role, 'risk.review');

  const casesQuery = useQuery({
    queryKey: ['risk', 'cases'],
    queryFn: () => riskRepository.listCases(),
    enabled: mayRead,
  });

  useEffect(() => {
    if (casesQuery.error && isSessionError(casesQuery.error)) router.replace('/sign-in');
  }, [casesQuery.error, router]);

  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const runAction = (fn: () => Promise<unknown>, onSuccess?: () => void) => {
    setBusy(true);
    setActionError(null);
    void (async () => {
      try {
        await fn();
        onSuccess?.();
        void queryClient.invalidateQueries({ queryKey: ['risk'] });
      } catch (e) {
        if (isSessionError(e)) {
          router.replace('/sign-in');
        } else {
          setActionError(errorText(e));
        }
      } finally {
        setBusy(false);
      }
    })();
  };

  const cases = casesQuery.data ?? [];
  const selected = cases.find((c) => c.id === selectedId);

  const columns: Column<RiskCase>[] = [
    { key: 'id', label: dict.risk.columns.id, render: (c) => c.id },
    { key: 'user', label: dict.risk.columns.user, render: (c) => c.subjectName },
    { key: 'kind', label: dict.risk.columns.kind, render: (c) => riskKindLabel(c.kind) },
    {
      key: 'signals',
      label: dict.risk.columns.signals,
      render: (c) => c.signals.length,
    },
    {
      key: 'status',
      label: dict.risk.columns.status,
      render: (c) => riskStatusChip(c.status),
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
        {dict.risk.title}
      </h1>

      {casesQuery.isPending ? (
        <StateBlock variant="loading" />
      ) : casesQuery.isError ? (
        <StateBlock
          variant="error"
          errorMessage={errorText(casesQuery.error)}
          retryLabel={dict.common.retry}
          onRetry={() => void casesQuery.refetch()}
        />
      ) : (
        <DataTable
          columns={columns}
          rows={cases}
          keyOf={(c) => c.id}
          emptyTitle={dict.common.emptyGeneric}
          onRowClick={(c) => {
            setActionError(null);
            setSelectedId(c.id);
          }}
        />
      )}

      <Drawer
        open={selectedId !== null}
        onClose={() => setSelectedId(null)}
        title={selected?.id ?? ''}
        closeLabel={dict.common.close}
      >
        {selected ? (
          <>
            <RiskDetail riskCase={selected} mayReview={mayReview} onAction={runAction} />
            {busy ? (
              <p
                aria-busy="true"
                className="mt-md text-body-small text-ink-secondary dark:text-ink-dark-secondary"
              >
                {dict.common.loading}
              </p>
            ) : null}
            {actionError ? (
              <p role="alert" className="mt-md text-body-small text-error dark:text-error-dark">
                {actionError}
              </p>
            ) : null}
          </>
        ) : (
          <StateBlock variant="loading" />
        )}
      </Drawer>
    </div>
  );
}
