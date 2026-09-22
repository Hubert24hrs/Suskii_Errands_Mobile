'use client';

import { useEffect, useState } from 'react';
import type { Dictionary } from '@/lib/i18n/en';
import { newIdempotencyKey } from '@/lib/idempotency';
import { disputeRepository } from '@/mocks/repositories';
import type { Dispute } from '@/mocks/types';
import { Modal } from '@/components/Modal';
import { StatusChip } from '@/components/StatusChip';
import { errorText, formatDateTime } from '../_shared';

const REASON_KEYS = ['not_delivered', 'damaged', 'late', 'other'] as const;

function disputeReasonLabel(dict: Dictionary, reasonKey: string): string {
  const table = dict.disputes.sheet.reasons as Record<string, string>;
  return table[reasonKey] ?? reasonKey;
}

function disputeStatusLabel(dict: Dictionary, status: Dispute['status']): string {
  const table = dict.disputes.statuses as Record<string, string>;
  return table[status] ?? status;
}

function DisputeCard({ dispute, dict }: { dispute: Dispute; dict: Dictionary }) {
  return (
    <div className="rounded-lg border border-outline bg-surface-raised p-xl dark:border-outline-dark dark:bg-surface-dark-raised">
      <div className="flex flex-wrap items-center justify-between gap-md">
        <p className="text-title-large text-ink-primary dark:text-ink-dark-primary">
          {disputeReasonLabel(dict, dispute.reasonKey)}
        </p>
        <StatusChip
          label={disputeStatusLabel(dict, dispute.status)}
          tone={dispute.status === 'resolved' ? 'success' : 'warning'}
        />
      </div>
      <p className="mt-sm text-body-small text-ink-secondary dark:text-ink-dark-secondary">
        {formatDateTime(dispute.createdAt)}
      </p>
      {dispute.status === 'resolved' && dispute.refundAmount ? (
        <p className="mt-sm text-body-small text-ink-secondary dark:text-ink-dark-secondary">
          {dict.disputes.resolvedPartialRefundNote}
        </p>
      ) : null}
    </div>
  );
}

export function DisputeSection({
  jobId,
  dict,
}: {
  jobId: string;
  dict: Dictionary;
}) {
  const [dispute, setDispute] = useState<Dispute | undefined>(undefined);
  useEffect(() => disputeRepository.watchDispute(jobId, setDispute), [jobId]);

  const [open, setOpen] = useState(false);
  const [reasonKey, setReasonKey] = useState<string>(REASON_KEYS[0]);
  const [details, setDetails] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // One key per dispute intent; reset when the modal (re)opens or inputs change.
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
      setOpen(false);
    } catch (e) {
      setError(errorText(dict, e));
    } finally {
      setBusy(false);
    }
  };

  if (dispute) {
    return (
      <section className="mt-xxl">
        <h2 className="text-title-large text-ink-primary dark:text-ink-dark-primary">
          {dict.disputes.title}
        </h2>
        <div className="mt-lg">
          <DisputeCard dispute={dispute} dict={dict} />
        </div>
      </section>
    );
  }

  return (
    <section className="mt-xxl">
      <button
        type="button"
        onClick={() => {
          setError(null);
          setOpen(true);
        }}
        className="rounded-md border border-outline px-lg py-sm text-label-large text-ink-primary transition-colors duration-normal ease-standard hover:bg-surface-muted dark:border-outline-dark dark:text-ink-dark-primary dark:hover:bg-surface-dark-muted"
      >
        {dict.disputes.openCta}
      </button>

      <Modal
        open={open}
        onClose={() => setOpen(false)}
        title={dict.disputes.sheet.title}
        closeLabel={dict.common.close}
      >
        <div className="flex flex-col gap-lg">
          <fieldset className="flex flex-col gap-xs">
            <legend className="text-label-large text-ink-primary dark:text-ink-dark-primary">
              {dict.disputes.sheet.reasonLabel}
            </legend>
            {REASON_KEYS.map((key) => (
              <label
                key={key}
                className="flex items-center gap-sm text-body-medium text-ink-primary dark:text-ink-dark-primary"
              >
                <input
                  type="radio"
                  name="dispute-reason"
                  value={key}
                  checked={reasonKey === key}
                  onChange={() => setReasonKey(key)}
                />
                {dict.disputes.sheet.reasons[key]}
              </label>
            ))}
          </fieldset>
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
      </Modal>
    </section>
  );
}
