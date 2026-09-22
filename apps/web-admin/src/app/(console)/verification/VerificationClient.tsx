'use client';

import { useEffect, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { dict } from '@/lib/i18n';
import { newIdempotencyKey } from '@/lib/idempotency';
import { verificationRepository } from '@/mocks/repositories';
import type { VerificationKind, VerificationQueueItem } from '@/mocks/types';
import { DataTable, type Column } from '@/components/DataTable';
import { Modal } from '@/components/Modal';
import { StateBlock } from '@/components/StateBlock';
import { StatusChip } from '@/components/StatusChip';
import { can, errorText, formatDateTime, isSessionError, useAdminSession } from '../_shared';
import { VerificationDrawer } from './VerificationDrawer';

const KINDS: VerificationKind[] = [
  'id_document',
  'facial',
  'police_clearance',
  'vehicle_document',
  'business_document',
];

const REJECTION_REASON_KEYS = Object.keys(dict.verification.rejectionReasons);

function statusChip(status: VerificationQueueItem['status']) {
  const label = (dict.verification.statuses as Record<string, string>)[status] ?? status;
  const tone =
    status === 'approved'
      ? 'success'
      : status === 'rejected'
        ? 'error'
        : status === 'in_review'
          ? 'warning'
          : 'neutral';
  return <StatusChip label={label} tone={tone} />;
}

export function VerificationClient() {
  const router = useRouter();
  const queryClient = useQueryClient();
  const sessionQuery = useAdminSession();
  const role = sessionQuery.data?.admin.role;
  const mayReview = role !== undefined && can(role, 'verification.review');
  const mayRead = role !== undefined && can(role, 'verification.read');

  const [kind, setKind] = useState<VerificationKind>('id_document');
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [rejectTarget, setRejectTarget] = useState<string | null>(null);
  const [rejectReason, setRejectReason] = useState(REJECTION_REASON_KEYS[0]);
  const [actionError, setActionError] = useState<string | null>(null);

  // One idempotency key per (action, item) intent; deleted after success.
  const intentKeys = useRef<Record<string, string>>({});
  const keyFor = (name: string) =>
    (intentKeys.current[name] ??= newIdempotencyKey());

  const queueQuery = useQuery({
    queryKey: ['verification', kind],
    queryFn: () => verificationRepository.listQueue({ kind }),
    enabled: mayRead,
  });

  useEffect(() => {
    if (queueQuery.error && isSessionError(queueQuery.error)) router.replace('/sign-in');
  }, [queueQuery.error, router]);

  const refresh = () => void queryClient.invalidateQueries({ queryKey: ['verification'] });

  const onMutationError = (e: unknown) => {
    if (isSessionError(e)) {
      router.replace('/sign-in');
      return;
    }
    // ERR_ALREADY_REVIEWED lands here and renders its dedicated dict copy.
    setActionError(errorText(e));
  };

  const claim = useMutation({
    mutationFn: (itemId: string) =>
      verificationRepository.claim(itemId, keyFor(`claim:${itemId}`)),
    onSuccess: (_item, itemId) => {
      delete intentKeys.current[`claim:${itemId}`];
      setActionError(null);
      refresh();
    },
    onError: onMutationError,
  });

  const approve = useMutation({
    mutationFn: (itemId: string) =>
      verificationRepository.approve(itemId, keyFor(`approve:${itemId}`)),
    onSuccess: (_item, itemId) => {
      delete intentKeys.current[`approve:${itemId}`];
      setActionError(null);
      refresh();
    },
    onError: onMutationError,
  });

  const reject = useMutation({
    mutationFn: ({ itemId, reasonKey }: { itemId: string; reasonKey: string }) =>
      verificationRepository.reject(itemId, reasonKey, keyFor(`reject:${itemId}:${reasonKey}`)),
    onSuccess: (_item, { itemId, reasonKey }) => {
      delete intentKeys.current[`reject:${itemId}:${reasonKey}`];
      setActionError(null);
      setRejectTarget(null);
      refresh();
    },
    onError: onMutationError,
  });

  const columns: Column<VerificationQueueItem>[] = [
    {
      key: 'subject',
      label: dict.verification.columns.subject,
      render: (item) => item.subjectName,
    },
    {
      key: 'country',
      label: dict.verification.columns.country,
      render: (item) =>
        (dict.dashboard.countries as Record<string, string>)[item.country] ?? item.country,
    },
    {
      key: 'submitted',
      label: dict.verification.columns.submitted,
      render: (item) => formatDateTime(item.submittedAt),
    },
    {
      key: 'priority',
      label: dict.verification.columns.priority,
      render: (item) => (
        <StatusChip
          label={dict.verification.priority[item.priority]}
          tone={item.priority === 'high' ? 'warning' : 'neutral'}
        />
      ),
    },
    {
      key: 'status',
      label: dict.verification.columns.status,
      render: (item) => statusChip(item.status),
    },
    {
      key: 'actions',
      label: dict.verification.columns.actions,
      render: (item) => {
        if (!mayReview || item.status === 'approved' || item.status === 'rejected') {
          return null;
        }
        return (
          <div
            className="flex flex-wrap gap-sm"
            onClick={(e) => e.stopPropagation()}
          >
            {item.status === 'queued' ? (
              <button
                type="button"
                disabled={claim.isPending}
                onClick={() => claim.mutate(item.id)}
                className="rounded-md border border-outline px-md py-xs text-label-large text-ink-primary transition-colors duration-normal ease-standard hover:bg-surface-muted disabled:opacity-50 dark:border-outline-dark dark:text-ink-dark-primary dark:hover:bg-surface-dark-muted"
              >
                {dict.verification.claimCta}
              </button>
            ) : null}
            {item.status === 'in_review' ? (
              <>
                <button
                  type="button"
                  disabled={approve.isPending}
                  onClick={() => approve.mutate(item.id)}
                  className="rounded-md bg-brand-primary px-md py-xs text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong disabled:opacity-50"
                >
                  {dict.verification.approveCta}
                </button>
                <button
                  type="button"
                  disabled={reject.isPending}
                  onClick={() => {
                    setActionError(null);
                    setRejectTarget(item.id);
                  }}
                  className="rounded-md border border-error px-md py-xs text-label-large text-error transition-colors duration-normal ease-standard hover:bg-error/10 disabled:opacity-50 dark:border-error-dark dark:text-error-dark dark:hover:bg-error-dark/20"
                >
                  {dict.verification.rejectCta}
                </button>
              </>
            ) : null}
          </div>
        );
      },
    },
  ];

  if (sessionQuery.isPending) {
    return <StateBlock variant="loading" />;
  }
  if (!mayRead) {
    // Defense in depth: the nav hides this module, and the repo re-checks.
    return (
      <StateBlock variant="error" errorMessage={dict.errors.ERR_PERMISSION_DENIED} />
    );
  }

  return (
    <div className="flex flex-col gap-xl">
      <h1 className="text-headline-medium text-ink-primary dark:text-ink-dark-primary">
        {dict.verification.title}
      </h1>

      <div className="flex flex-wrap gap-sm" role="tablist" aria-label={dict.verification.title}>
        {KINDS.map((k) => (
          <button
            key={k}
            type="button"
            role="tab"
            aria-selected={kind === k}
            onClick={() => setKind(k)}
            className={`rounded-pill px-lg py-sm text-label-large transition-colors duration-normal ease-standard ${
              kind === k
                ? 'bg-brand-primary text-brand-on-primary'
                : 'border border-outline text-ink-primary hover:bg-surface-muted dark:border-outline-dark dark:text-ink-dark-primary dark:hover:bg-surface-dark-muted'
            }`}
          >
            {dict.verification.tabs[k]}
          </button>
        ))}
      </div>

      {actionError ? (
        <p role="alert" className="text-body-small text-error dark:text-error-dark">
          {actionError}
        </p>
      ) : null}

      {queueQuery.isPending ? (
        <StateBlock variant="loading" />
      ) : queueQuery.isError ? (
        <StateBlock
          variant="error"
          errorMessage={errorText(queueQuery.error)}
          retryLabel={dict.common.retry}
          onRetry={() => void queueQuery.refetch()}
        />
      ) : (
        <DataTable
          columns={columns}
          rows={queueQuery.data}
          keyOf={(item) => item.id}
          emptyTitle={dict.common.emptyGeneric}
          onRowClick={(item) => setSelectedId(item.id)}
        />
      )}

      <Modal
        open={rejectTarget !== null}
        onClose={() => setRejectTarget(null)}
        title={dict.verification.rejectCta}
        closeLabel={dict.common.close}
      >
        <div className="flex flex-col gap-lg">
          <div className="flex flex-col gap-xs">
            <label
              htmlFor="reject-reason"
              className="text-label-large text-ink-primary dark:text-ink-dark-primary"
            >
              {dict.common.reason}
            </label>
            <select
              id="reject-reason"
              value={rejectReason}
              onChange={(e) => setRejectReason(e.target.value)}
              className="rounded-md border border-outline bg-surface-raised px-md py-sm text-body-large text-ink-primary outline-none transition-colors duration-normal ease-standard focus:border-brand-primary dark:border-outline-dark dark:bg-surface-dark-raised dark:text-ink-dark-primary"
            >
              {REJECTION_REASON_KEYS.map((key) => (
                <option key={key} value={key}>
                  {(dict.verification.rejectionReasons as Record<string, string>)[key]}
                </option>
              ))}
            </select>
          </div>
          <div className="flex gap-md">
            <button
              type="button"
              disabled={reject.isPending || rejectTarget === null}
              onClick={() => {
                if (rejectTarget) {
                  reject.mutate({ itemId: rejectTarget, reasonKey: rejectReason });
                }
              }}
              className="rounded-md bg-error px-xl py-sm text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:opacity-90 disabled:opacity-50 dark:bg-error-dark"
            >
              {dict.common.confirm}
            </button>
            <button
              type="button"
              onClick={() => setRejectTarget(null)}
              className="rounded-md border border-outline px-lg py-sm text-label-large text-ink-primary transition-colors duration-normal ease-standard hover:bg-surface-muted dark:border-outline-dark dark:text-ink-dark-primary dark:hover:bg-surface-dark-muted"
            >
              {dict.common.cancel}
            </button>
          </div>
        </div>
      </Modal>

      <VerificationDrawer itemId={selectedId} onClose={() => setSelectedId(null)} />
    </div>
  );
}
