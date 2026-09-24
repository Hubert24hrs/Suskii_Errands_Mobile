'use client';

// Publish card proposed by the concierge (proposedAction = show_publish_card).
// The concierge never publishes itself — this button is the user's own tap,
// routed through RequestRepository.publishRequest like any draft. Money
// fields render only when the draft actually carries them (the concierge
// never fills money); nothing is invented here.

import { useRef, useState } from 'react';
import Link from 'next/link';
import type { Dictionary } from '@/lib/i18n/en';
import type { Locale } from '@/lib/i18n';
import { newIdempotencyKey } from '@/lib/idempotency';
import { isAppError, requestRepository } from '@/lib/repositories';
import type { ConciergeDraft } from '@/mocks/types';
import { MoneyText } from '@/components/MoneyText';
import { StatusChip } from '@/components/StatusChip';
import { errorText, urgencyLabel } from '../requests/_shared';

const rowLabelClasses = 'text-label-small text-ink-secondary dark:text-ink-dark-secondary';
const rowValueClasses = 'text-body-medium text-ink-primary dark:text-ink-dark-primary';

function SummaryRow({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex flex-col gap-xxs">
      <dt className={rowLabelClasses}>{label}</dt>
      <dd className={rowValueClasses}>{value}</dd>
    </div>
  );
}

function MoneyRow({
  label,
  amountMinor,
  currency,
}: {
  label: string;
  amountMinor: number;
  currency: string;
}) {
  return (
    <div className="flex flex-col gap-xxs">
      <dt className={rowLabelClasses}>{label}</dt>
      <dd className={rowValueClasses}>
        <MoneyText amountMinor={amountMinor} currency={currency} />
      </dd>
    </div>
  );
}

export function PublishCard({
  locale,
  dict,
  draft,
  categoryName,
}: {
  locale: Locale;
  dict: Dictionary;
  draft: ConciergeDraft;
  categoryName: string;
}) {
  // ONE key held from the moment the card appears: retries of the same
  // publish tap replay, and the concierge replaying its proposal never
  // rotates the user's intent key.
  const publishKeyRef = useRef<string | null>(null);
  if (publishKeyRef.current === null) {
    publishKeyRef.current = newIdempotencyKey();
  }

  const [pending, setPending] = useState(false);
  const [publishedId, setPublishedId] = useState<string | null>(null);
  const [verificationRequired, setVerificationRequired] = useState(false);
  const [error, setError] = useState<unknown>(null);

  const publish = async () => {
    // The server-side draft id arrives asynchronously; until it is patched
    // onto the draft there is nothing publishable.
    const key = publishKeyRef.current;
    if (draft.requestId === undefined || key === null || pending || publishedId !== null) {
      return;
    }
    setPending(true);
    setError(null);
    setVerificationRequired(false);
    try {
      const published = await requestRepository.publishRequest(draft.requestId, key);
      setPublishedId(published.id);
    } catch (e) {
      if (isAppError(e, 'ERR_VERIFICATION_REQUIRED')) {
        setVerificationRequired(true);
      } else {
        setError(e);
      }
    } finally {
      setPending(false);
    }
  };

  return (
    <div className="mt-sm w-full max-w-md rounded-lg border border-outline bg-surface-raised p-lg dark:border-outline-dark dark:bg-surface-dark-raised">
      <h3 className="text-title-medium text-ink-primary dark:text-ink-dark-primary">
        {dict.concierge.publishCard.title}
      </h3>
      <p className="mt-xs text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
        {dict.concierge.publishCard.body}
      </p>

      <dl className="mt-md flex flex-col gap-sm">
        {draft.categoryId !== undefined ? (
          <SummaryRow label={dict.concierge.slotChips.category} value={categoryName} />
        ) : null}
        {draft.description !== undefined && draft.description !== '' ? (
          <SummaryRow label={dict.requests.detail.description} value={draft.description} />
        ) : null}
        {draft.pickup !== undefined && draft.pickup.label !== '' ? (
          <SummaryRow label={dict.requests.detail.pickup} value={draft.pickup.label} />
        ) : null}
        {draft.destination !== undefined && draft.destination.label !== '' ? (
          <SummaryRow
            label={dict.requests.detail.destination}
            value={draft.destination.label}
          />
        ) : null}
        {draft.urgency !== undefined ? (
          <SummaryRow
            label={dict.requests.detail.urgency}
            value={urgencyLabel(dict, draft.urgency)}
          />
        ) : null}
        {draft.preferredPrice !== undefined ? (
          <MoneyRow
            label={dict.requests.detail.preferredPrice}
            amountMinor={draft.preferredPrice.amountMinor}
            currency={draft.preferredPrice.currency}
          />
        ) : null}
        {draft.itemFloat !== undefined ? (
          <MoneyRow
            label={dict.requests.detail.itemFloat}
            amountMinor={draft.itemFloat.amountMinor}
            currency={draft.itemFloat.currency}
          />
        ) : null}
        {draft.declaredValue !== undefined ? (
          <MoneyRow
            label={dict.requests.detail.declaredValue}
            amountMinor={draft.declaredValue.amountMinor}
            currency={draft.declaredValue.currency}
          />
        ) : null}
      </dl>

      {publishedId !== null ? (
        <div className="mt-md flex flex-wrap items-center gap-md">
          <StatusChip label={dict.requests.statuses.published} tone="success" />
          <Link
            href={`/${locale}/requests/${publishedId}`}
            className="rounded-md bg-brand-primary px-lg py-sm text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong"
          >
            {dict.requests.detail.title}
          </Link>
        </div>
      ) : (
        <button
          type="button"
          disabled={draft.requestId === undefined || pending}
          onClick={() => void publish()}
          className="mt-md rounded-md bg-brand-primary px-xl py-md text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong disabled:opacity-50"
        >
          {dict.concierge.publishCard.confirm}
        </button>
      )}

      {verificationRequired ? (
        <div className="mt-md rounded-md border border-warning bg-warning/10 p-md dark:border-warning-dark dark:bg-warning-dark/20">
          <p className="text-body-medium text-ink-primary dark:text-ink-dark-primary">
            {dict.newRequest.verificationRequiredNotice}
          </p>
          <Link
            href={`/${locale}/verify`}
            className="mt-sm inline-block rounded-md bg-brand-primary px-lg py-sm text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong"
          >
            {dict.verify.title}
          </Link>
        </div>
      ) : null}

      {error !== null && !verificationRequired ? (
        <p role="alert" className="mt-md text-body-medium text-error dark:text-error-dark">
          {errorText(dict, error)}
        </p>
      ) : null}
    </div>
  );
}
