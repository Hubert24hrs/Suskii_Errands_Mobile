'use client';

import { useEffect, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { dict } from '@/lib/i18n';
import { newIdempotencyKey } from '@/lib/idempotency';
import { sosRepository } from '@/mocks/repositories';
import type { SosAlertAdmin, SosStatus } from '@/mocks/types';
import { DataTable, type Column } from '@/components/DataTable';
import { Drawer } from '@/components/Drawer';
import { StateBlock } from '@/components/StateBlock';
import { StatusChip } from '@/components/StatusChip';
import { can, errorText, formatDateTime, isSessionError, useAdminSession } from '../_shared';

function sosStatusChip(status: SosStatus) {
  const label = (dict.sos.statuses as Record<string, string>)[status] ?? status;
  const tone =
    status === 'active' ? 'error' : status === 'acknowledged' ? 'warning' : 'success';
  return <StatusChip label={label} tone={tone} />;
}

const inputClass =
  'w-full rounded-md border border-outline bg-surface px-md py-sm text-body-large text-ink-primary outline-none transition-colors duration-normal ease-standard focus:border-brand-primary dark:border-outline-dark dark:bg-surface-dark dark:text-ink-dark-primary';

function AlertDetail({
  alert,
  mayManage,
  onAction,
}: {
  alert: SosAlertAdmin;
  mayManage: boolean;
  onAction: (fn: () => Promise<unknown>, onSuccess?: () => void) => void;
}) {
  // One key per acknowledge intent; kept for retries, deleted after success.
  const ackKeys = useRef<Record<string, string>>({});
  // One key per resolve intent — the note is part of the args hash, so the
  // key rotates whenever the note changes (like the payments reject flow).
  const [resolveNote, setResolveNote] = useState('');
  const [resolveKey, setResolveKey] = useState(() => newIdempotencyKey());

  return (
    <div className="flex flex-col gap-lg">
      <div className="flex flex-wrap items-center gap-md">{sosStatusChip(alert.status)}</div>

      <div className="divide-y divide-outline dark:divide-outline-dark">
        <div className="flex flex-wrap justify-between gap-md py-sm">
          <span className="text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
            {dict.sos.columns.user}
          </span>
          <span className="text-body-medium text-ink-primary dark:text-ink-dark-primary">
            {alert.userName} · {alert.userPhone}
          </span>
        </div>
        <div className="flex flex-wrap justify-between gap-md py-sm">
          <span className="text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
            {dict.sos.columns.job}
          </span>
          <span className="text-body-medium text-ink-primary dark:text-ink-dark-primary">
            {alert.jobId}
          </span>
        </div>
        <div className="flex flex-wrap justify-between gap-md py-sm">
          <span className="text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
            {dict.sos.columns.triggered}
          </span>
          <span className="text-body-medium text-ink-primary dark:text-ink-dark-primary">
            {formatDateTime(alert.triggeredAt)}
          </span>
        </div>
        {alert.acknowledgedByAdminId ? (
          <div className="flex flex-wrap justify-between gap-md py-sm">
            <span className="text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
              {dict.sos.acknowledgeCta}
            </span>
            <span className="text-body-medium text-ink-primary dark:text-ink-dark-primary">
              {alert.acknowledgedByAdminId}
              {alert.acknowledgedAt ? ` · ${formatDateTime(alert.acknowledgedAt)}` : ''}
            </span>
          </div>
        ) : null}
      </div>

      <p className="rounded-md border border-error/40 bg-error/10 px-md py-sm text-body-medium text-error dark:border-error-dark/40 dark:bg-error-dark/20 dark:text-error-dark">
        {dict.sos.emergencyGuidance}
      </p>

      <section className="flex flex-col gap-sm">
        <p className="text-body-small text-ink-secondary dark:text-ink-dark-secondary">
          {dict.sos.locationTrailNote}
        </p>
        {/* Latest ping first. Coordinates as text — the map is mocked. */}
        <ul className="flex max-h-64 flex-col gap-xs overflow-y-auto rounded-md border border-outline p-md dark:border-outline-dark">
          {[...alert.trail].reverse().map((ping, i) => (
            <li
              key={`${ping.at.getTime()}-${i}`}
              className="flex flex-wrap justify-between gap-md text-body-small text-ink-primary dark:text-ink-dark-primary"
            >
              <span>{formatDateTime(ping.at)}</span>
              <span className="font-mono">
                {ping.point.latitude.toFixed(5)}, {ping.point.longitude.toFixed(5)}
              </span>
            </li>
          ))}
        </ul>
      </section>

      {alert.status === 'resolved' ? (
        <div className="flex flex-col gap-sm">
          <p className="text-body-medium text-success dark:text-success-dark">
            {dict.sos.resolvedNote}
          </p>
          {alert.resolutionNote ? (
            <p className="text-body-medium text-ink-primary dark:text-ink-dark-primary">
              {alert.resolutionNote}
            </p>
          ) : null}
          {alert.resolvedAt ? (
            <p className="text-body-small text-ink-secondary dark:text-ink-dark-secondary">
              {formatDateTime(alert.resolvedAt)}
            </p>
          ) : null}
        </div>
      ) : mayManage ? (
        <div className="flex flex-col gap-md">
          {alert.status === 'active' ? (
            <div>
              <button
                type="button"
                onClick={() =>
                  onAction(async () => {
                    const key = (ackKeys.current[alert.id] ??= newIdempotencyKey());
                    await sosRepository.acknowledge(alert.id, key);
                    delete ackKeys.current[alert.id];
                  })
                }
                className="rounded-md bg-brand-primary px-xl py-sm text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong"
              >
                {dict.sos.acknowledgeCta}
              </button>
            </div>
          ) : null}

          <div className="flex flex-col gap-xs">
            <label
              htmlFor="sos-resolve-note"
              className="text-label-large text-ink-primary dark:text-ink-dark-primary"
            >
              {dict.common.reason}
            </label>
            <textarea
              id="sos-resolve-note"
              rows={3}
              value={resolveNote}
              onChange={(e) => {
                setResolveNote(e.target.value);
                setResolveKey(newIdempotencyKey());
              }}
              placeholder={dict.common.reasonPlaceholder}
              className={inputClass}
            />
          </div>
          <div>
            <button
              type="button"
              disabled={resolveNote.trim() === ''}
              onClick={() =>
                onAction(
                  () => sosRepository.resolve(alert.id, resolveNote.trim(), resolveKey),
                  () => {
                    setResolveNote('');
                    setResolveKey(newIdempotencyKey());
                  },
                )
              }
              className="rounded-md bg-brand-primary px-xl py-sm text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong disabled:opacity-50"
            >
              {dict.sos.resolveCta}
            </button>
          </div>
        </div>
      ) : null}
    </div>
  );
}

export function SosClient() {
  const router = useRouter();
  const queryClient = useQueryClient();
  const sessionQuery = useAdminSession();
  const role = sessionQuery.data?.admin.role;
  const mayRead = role !== undefined && can(role, 'sos.read');
  const mayManage = role !== undefined && can(role, 'sos.manage');

  const alertsQuery = useQuery({
    queryKey: ['sos', 'alerts'],
    queryFn: () => sosRepository.listAlerts(),
    enabled: mayRead,
  });

  // Live operations feed: alert updates (incl. trail ticks) merge into the
  // query cache, so the banner, table and open drawer all stay current.
  useEffect(() => {
    if (!mayRead) return;
    try {
      return sosRepository.watchAlerts((alert) => {
        queryClient.setQueryData<SosAlertAdmin[]>(['sos', 'alerts'], (current) => {
          if (!current) return current;
          const idx = current.findIndex((a) => a.id === alert.id);
          if (idx === -1) return [...current, alert];
          const next = [...current];
          next[idx] = alert;
          return next;
        });
      });
    } catch (e) {
      // watchAlerts checks the session synchronously.
      if (isSessionError(e)) router.replace('/sign-in');
      return undefined;
    }
  }, [mayRead, queryClient, router]);

  useEffect(() => {
    if (alertsQuery.error && isSessionError(alertsQuery.error)) router.replace('/sign-in');
  }, [alertsQuery.error, router]);

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
        void queryClient.invalidateQueries({ queryKey: ['sos'] });
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

  const alerts = alertsQuery.data ?? [];
  const activeCount = alerts.filter((a) => a.status === 'active').length;
  const selected = alerts.find((a) => a.id === selectedId);

  const columns: Column<SosAlertAdmin>[] = [
    { key: 'id', label: dict.sos.columns.id, render: (a) => a.id },
    {
      key: 'user',
      label: dict.sos.columns.user,
      render: (a) => (
        <span>
          <span className="block text-label-large">{a.userName}</span>
          <span className="block text-body-small text-ink-secondary dark:text-ink-dark-secondary">
            {a.userPhone}
          </span>
        </span>
      ),
    },
    { key: 'job', label: dict.sos.columns.job, render: (a) => a.jobId },
    {
      key: 'triggered',
      label: dict.sos.columns.triggered,
      render: (a) => formatDateTime(a.triggeredAt),
    },
    {
      key: 'status',
      label: dict.sos.columns.status,
      render: (a) => sosStatusChip(a.status),
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
        {dict.sos.title}
      </h1>

      {activeCount > 0 ? (
        <div
          role="alert"
          className="rounded-lg border border-error bg-error/10 p-lg dark:border-error-dark dark:bg-error-dark/20"
        >
          <p className="text-title-large text-error dark:text-error-dark">
            {dict.sos.activeBannerTitle}
          </p>
          <p className="mt-xs text-body-medium text-ink-primary dark:text-ink-dark-primary">
            {dict.sos.activeBannerBody}
          </p>
        </div>
      ) : null}

      {alertsQuery.isPending ? (
        <StateBlock variant="loading" />
      ) : alertsQuery.isError ? (
        <StateBlock
          variant="error"
          errorMessage={errorText(alertsQuery.error)}
          retryLabel={dict.common.retry}
          onRetry={() => void alertsQuery.refetch()}
        />
      ) : (
        <DataTable
          columns={columns}
          rows={alerts}
          keyOf={(a) => a.id}
          emptyTitle={dict.common.emptyGeneric}
          onRowClick={(a) => {
            setActionError(null);
            setSelectedId(a.id);
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
            <AlertDetail alert={selected} mayManage={mayManage} onAction={runAction} />
            {busy ? (
              <p aria-busy="true" className="mt-md text-body-small text-ink-secondary dark:text-ink-dark-secondary">
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
