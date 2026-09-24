'use client';

import { useEffect, useState } from 'react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { useQuery } from '@tanstack/react-query';
import type { Dictionary } from '@/lib/i18n/en';
import type { Locale } from '@/lib/i18n';
import { newIdempotencyKey } from '@/lib/idempotency';
import { disputeRepository, isAppError } from '@/lib/repositories';
import type { Dispute, DisputeStatus } from '@/mocks/types';
import { Modal } from '@/components/Modal';
import { MoneyText } from '@/components/MoneyText';
import { StateBlock } from '@/components/StateBlock';
import { StatusChip } from '@/components/StatusChip';

const REASON_KEYS = ['not_delivered', 'damaged', 'late', 'other'] as const;

type ChipTone = 'neutral' | 'info' | 'success' | 'warning' | 'error';

/** Maps any error to localized copy; unknown codes fall back to ERR_INTERNAL. */
function errorText(dict: Dictionary, error: unknown): string {
  if (isAppError(error)) {
    const table = dict.errors as Record<string, string>;
    return table[error.code] ?? dict.errors.ERR_INTERNAL;
  }
  return dict.errors.ERR_INTERNAL;
}

function reasonLabel(dict: Dictionary, reasonKey: string): string {
  const table = dict.disputes.sheet.reasons as Record<string, string>;
  return table[reasonKey] ?? reasonKey;
}

function statusLabel(dict: Dictionary, status: DisputeStatus): string {
  const table = dict.disputes.statuses as Record<string, string>;
  return table[status] ?? status;
}

function statusTone(status: DisputeStatus): ChipTone {
  switch (status) {
    case 'open':
      return 'warning';
    case 'in_review':
      return 'info';
    case 'resolved':
      return 'success';
    case 'rejected':
      return 'error';
  }
}

/** en-NG formatting for both locales (pcm has no Intl locale data). */
function formatDateTime(date: Date): string {
  return new Intl.DateTimeFormat('en-NG', {
    dateStyle: 'medium',
    timeStyle: 'short',
  }).format(date);
}

function ResolvedNote({ dispute, dict }: { dispute: Dispute; dict: Dictionary }) {
  if (dispute.status !== 'resolved') return null;
  return (
    <p className="mt-sm text-body-small text-ink-secondary dark:text-ink-dark-secondary">
      {dict.disputes.resolvedPartialRefundNote}
      {dispute.refundAmount ? (
        <>
          {' '}
          <MoneyText
            amountMinor={dispute.refundAmount.amountMinor}
            currency={dispute.refundAmount.currency}
          />
        </>
      ) : null}
    </p>
  );
}

/** One dispute row; watchDispute keeps the status live (mock ops resolves it). */
function DisputeRow({
  dispute: initial,
  locale,
  dict,
}: {
  dispute: Dispute;
  locale: Locale;
  dict: Dictionary;
}) {
  const [dispute, setDispute] = useState(initial);
  useEffect(
    () =>
      disputeRepository.watchDispute(initial.jobId, (d) => {
        if (d) setDispute(d);
      }),
    [initial.jobId],
  );

  return (
    <div className="rounded-lg border border-outline bg-surface-raised p-xl dark:border-outline-dark dark:bg-surface-dark-raised">
      <div className="flex flex-wrap items-center justify-between gap-md">
        <p className="text-title-large text-ink-primary dark:text-ink-dark-primary">
          {reasonLabel(dict, dispute.reasonKey)}
        </p>
        <StatusChip label={statusLabel(dict, dispute.status)} tone={statusTone(dispute.status)} />
      </div>
      <div className="mt-sm flex flex-wrap items-center justify-between gap-md">
        <Link
          href={`/${locale}/requests/${dispute.jobId}`}
          className="text-body-small text-brand-primary underline-offset-2 transition-colors duration-normal ease-standard hover:underline dark:text-brand-secondary"
        >
          {dispute.jobId}
        </Link>
        <span className="text-body-small text-ink-secondary dark:text-ink-dark-secondary">
          {formatDateTime(dispute.createdAt)}
        </span>
      </div>
      {dispute.details ? (
        <p className="mt-sm text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
          {dispute.details}
        </p>
      ) : null}
      <ResolvedNote dispute={dispute} dict={dict} />
    </div>
  );
}

/**
 * New-dispute modal for one job (deep-linked via ?open=<jobId>). One dispute
 * per job: if the job already has one, the modal shows it instead of the form.
 */
function OpenDisputeModal({
  jobId,
  dict,
  onClose,
  onOpened,
}: {
  jobId: string;
  dict: Dictionary;
  onClose: () => void;
  onOpened: () => void;
}) {
  const [existing, setExisting] = useState<Dispute | undefined>(undefined);
  useEffect(() => disputeRepository.watchDispute(jobId, setExisting), [jobId]);

  const [reasonKey, setReasonKey] = useState<string>(REASON_KEYS[0]);
  const [details, setDetails] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // One key per dispute intent; reset after success or when inputs change.
  const [intent, setIntent] = useState<{ key: string; fingerprint: string } | null>(null);

  const submit = async () => {
    const fingerprint = `${reasonKey}|${details}`;
    const current =
      intent && intent.fingerprint === fingerprint
        ? intent
        : { key: newIdempotencyKey(), fingerprint };
    setIntent(current);
    setBusy(true);
    setError(null);
    try {
      await disputeRepository.openDispute({
        jobId,
        reasonKey,
        details: details.trim() === '' ? undefined : details.trim(),
        idempotencyKey: current.key,
      });
      setIntent(null);
      onOpened();
    } catch (e) {
      setError(errorText(dict, e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <Modal
      open
      onClose={onClose}
      title={dict.disputes.sheet.title}
      closeLabel={dict.common.close}
    >
      {existing ? (
        <div className="flex flex-col gap-md">
          <div className="flex flex-wrap items-center justify-between gap-md">
            <p className="text-body-large text-ink-primary dark:text-ink-dark-primary">
              {reasonLabel(dict, existing.reasonKey)}
            </p>
            <StatusChip
              label={statusLabel(dict, existing.status)}
              tone={statusTone(existing.status)}
            />
          </div>
          <ResolvedNote dispute={existing} dict={dict} />
        </div>
      ) : (
        <div className="flex flex-col gap-lg">
          <div className="flex flex-col gap-xs">
            <label
              htmlFor="dispute-reason"
              className="text-label-large text-ink-primary dark:text-ink-dark-primary"
            >
              {dict.disputes.sheet.reasonLabel}
            </label>
            <select
              id="dispute-reason"
              value={reasonKey}
              onChange={(e) => setReasonKey(e.target.value)}
              className="rounded-md border border-outline bg-surface-raised px-md py-sm text-body-large text-ink-primary outline-none transition-colors duration-normal ease-standard focus:border-brand-primary dark:border-outline-dark dark:bg-surface-dark-raised dark:text-ink-dark-primary"
            >
              {REASON_KEYS.map((key) => (
                <option key={key} value={key}>
                  {dict.disputes.sheet.reasons[key]}
                </option>
              ))}
            </select>
          </div>
          <div className="flex flex-col gap-xs">
            <label
              htmlFor="dispute-details"
              className="text-label-large text-ink-primary dark:text-ink-dark-primary"
            >
              {dict.disputes.sheet.detailsLabel}
            </label>
            <textarea
              id="dispute-details"
              rows={3}
              value={details}
              onChange={(e) => setDetails(e.target.value)}
              className="rounded-md border border-outline bg-surface-raised px-md py-sm text-body-large text-ink-primary outline-none transition-colors duration-normal ease-standard focus:border-brand-primary dark:border-outline-dark dark:bg-surface-dark-raised dark:text-ink-dark-primary"
            />
            <p className="text-body-small text-ink-secondary dark:text-ink-dark-secondary">
              {dict.disputes.sheet.evidenceHint}
            </p>
          </div>
          {error ? (
            <p role="alert" className="text-body-small text-error dark:text-error-dark">
              {error}
            </p>
          ) : null}
          <button
            type="button"
            disabled={busy}
            onClick={() => void submit()}
            className="rounded-md bg-brand-primary px-xl py-md text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong disabled:opacity-50"
          >
            {dict.disputes.sheet.submitCta}
          </button>
        </div>
      )}
    </Modal>
  );
}

export function DisputesClient({
  locale,
  dict,
  openJobId,
}: {
  locale: Locale;
  dict: Dictionary;
  openJobId: string | null;
}) {
  const router = useRouter();
  const query = useQuery({
    queryKey: ['disputes', 'mine'],
    queryFn: () => disputeRepository.getMyDisputes(),
  });

  const closeModal = () => router.replace(`/${locale}/disputes`);

  return (
    <div className="mx-auto w-full max-w-5xl px-lg py-xxxl">
      <h1 className="text-headline-medium text-ink-primary dark:text-ink-dark-primary">
        {dict.disputes.title}
      </h1>

      <div className="mt-xxl">
        {query.isPending ? (
          <StateBlock variant="loading" />
        ) : query.isError ? (
          <StateBlock
            variant="error"
            errorMessage={errorText(dict, query.error)}
            retryLabel={dict.common.retry}
            onRetry={() => void query.refetch()}
          />
        ) : (query.data ?? []).length === 0 ? (
          <StateBlock variant="empty" emptyTitle={dict.disputes.empty} />
        ) : (
          <ul className="flex flex-col gap-lg">
            {(query.data ?? []).map((dispute) => (
              <li key={dispute.id}>
                <DisputeRow dispute={dispute} locale={locale} dict={dict} />
              </li>
            ))}
          </ul>
        )}
      </div>

      {openJobId ? (
        <OpenDisputeModal
          key={openJobId}
          jobId={openJobId}
          dict={dict}
          onClose={closeModal}
          onOpened={() => {
            void query.refetch();
            closeModal();
          }}
        />
      ) : null}
    </div>
  );
}
