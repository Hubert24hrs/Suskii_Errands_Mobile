'use client';

import { useEffect, useState } from 'react';
import Link from 'next/link';
import { useQuery } from '@tanstack/react-query';
import type { Dictionary } from '@/lib/i18n/en';
import type { Locale } from '@/lib/i18n';
import { newIdempotencyKey } from '@/lib/idempotency';
import {
  catalogRepository,
  isAppError,
  jobProgressRepository,
  requestRepository,
} from '@/mocks/repositories';
import type { JobRequest, JobStatus } from '@/mocks/types';
import { MoneyText } from '@/components/MoneyText';
import { StateBlock } from '@/components/StateBlock';
import { StatusChip } from '@/components/StatusChip';
import { Timeline } from '@/components/Timeline';
import {
  categoryLabel,
  errorText,
  formatDateTime,
  mediaName,
  statusLabel,
  statusTone,
  urgencyLabel,
} from '../_shared';
import { OffersBoard } from './OffersBoard';
import { HandoverPinCard } from './HandoverPinCard';
import { RatingSheet } from './RatingSheet';
import { DisputeSection } from './DisputeSection';
import { CancelRequestButton } from './CancelRequestButton';

const COLLECTING: ReadonlySet<JobStatus> = new Set([
  'published',
  'offers_received',
  'negotiating',
]);

const CANCELLABLE: ReadonlySet<JobStatus> = new Set([
  'draft',
  'published',
  'offers_received',
  'negotiating',
  'agreed',
  'payment_pending',
]);

const IN_CONTACT: ReadonlySet<JobStatus> = new Set([
  'paid_held',
  'assigned',
  'en_route',
  'arrived',
  'in_progress',
  'completed_by_provider',
]);

const DISPUTABLE: ReadonlySet<JobStatus> = new Set([
  'paid_held',
  'assigned',
  'en_route',
  'arrived',
  'in_progress',
  'completed_by_provider',
  'confirmed',
  'disputed',
  'refunded',
]);

const RATEABLE: ReadonlySet<JobStatus> = new Set(['confirmed', 'settled', 'closed']);

const MILESTONE_LABELS = [
  'published',
  'offersReceived',
  'agreed',
  'paid',
  'inProgress',
  'completedByProvider',
  'confirmed',
] as const;

/** Furthest milestone reached for a progressing status; null when off-flow. */
function milestoneIndex(status: JobStatus): number | null {
  switch (status) {
    case 'published':
      return 0;
    case 'offers_received':
    case 'negotiating':
      return 1;
    case 'agreed':
    case 'payment_pending':
      return 2;
    case 'paid_held':
    case 'assigned':
    case 'en_route':
    case 'arrived':
      return 3;
    case 'in_progress':
      return 4;
    case 'completed_by_provider':
      return 5;
    case 'confirmed':
    case 'settlement_pending':
    case 'settled':
    case 'closed':
      return 6;
    default:
      return null;
  }
}

function SummaryRow({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex flex-wrap justify-between gap-md py-sm">
      <span className="text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
        {label}
      </span>
      <span className="text-body-medium text-ink-primary dark:text-ink-dark-primary">
        {value}
      </span>
    </div>
  );
}

function DraftPublishSection({
  job,
  locale,
  dict,
}: {
  job: JobRequest;
  locale: Locale;
  dict: Dictionary;
}) {
  // One key for the publish intent; reused on retry, regenerated on success.
  const [key, setKey] = useState(() => newIdempotencyKey());
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [verificationRequired, setVerificationRequired] = useState(false);

  const publish = async () => {
    setBusy(true);
    setError(null);
    try {
      await requestRepository.publishRequest(job.id, key);
      setKey(newIdempotencyKey());
    } catch (e) {
      if (isAppError(e, 'ERR_VERIFICATION_REQUIRED')) {
        setVerificationRequired(true);
      } else {
        setError(errorText(dict, e));
      }
    } finally {
      setBusy(false);
    }
  };

  return (
    <section className="mt-xxl">
      {verificationRequired ? (
        <div className="rounded-md border border-warning bg-warning/10 p-lg dark:border-warning-dark dark:bg-warning-dark/20">
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
      ) : (
        <button
          type="button"
          disabled={busy}
          onClick={() => void publish()}
          className="rounded-md bg-brand-primary px-xl py-md text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong disabled:opacity-50"
        >
          {dict.requests.publishCta}
        </button>
      )}
      {error ? (
        <p role="alert" className="mt-sm text-body-small text-error dark:text-error-dark">
          {error}
        </p>
      ) : null}
    </section>
  );
}

function ConfirmCompletionSection({ job, dict }: { job: JobRequest; dict: Dictionary }) {
  // One key for the confirm intent; reused on retry, regenerated on success.
  const [key, setKey] = useState(() => newIdempotencyKey());
  const [armed, setArmed] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const confirm = async () => {
    setBusy(true);
    setError(null);
    try {
      await jobProgressRepository.confirmCompletion(job.id, key);
      setKey(newIdempotencyKey());
      setArmed(false);
    } catch (e) {
      setError(errorText(dict, e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <section className="mt-xxl rounded-lg border border-outline bg-surface-raised p-xl dark:border-outline-dark dark:bg-surface-dark-raised">
      {armed ? (
        <>
          <p className="text-body-medium text-ink-primary dark:text-ink-dark-primary">
            {dict.requests.confirmCompletion.warning}
          </p>
          <div className="mt-md flex flex-wrap gap-md">
            <button
              type="button"
              disabled={busy}
              onClick={() => void confirm()}
              className="rounded-md bg-brand-primary px-xl py-md text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong disabled:opacity-50"
            >
              {dict.requests.confirmCompletion.confirm}
            </button>
            <button
              type="button"
              disabled={busy}
              onClick={() => setArmed(false)}
              className="rounded-md border border-outline px-xl py-md text-label-large text-ink-primary transition-colors duration-normal ease-standard hover:bg-surface-muted dark:border-outline-dark dark:text-ink-dark-primary dark:hover:bg-surface-dark-muted"
            >
              {dict.common.cancel}
            </button>
          </div>
        </>
      ) : (
        <button
          type="button"
          onClick={() => setArmed(true)}
          className="rounded-md bg-brand-primary px-xl py-md text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong"
        >
          {dict.requests.confirmCompletion.cta}
        </button>
      )}
      {error ? (
        <p role="alert" className="mt-sm text-body-small text-error dark:text-error-dark">
          {error}
        </p>
      ) : null}
    </section>
  );
}

export function RequestDetailClient({
  locale,
  jobId,
  dict,
}: {
  locale: Locale;
  jobId: string;
  dict: Dictionary;
}) {
  // Baseline fetch (also resolves unknown ids), live updates via watchJob.
  const mineQuery = useQuery({
    queryKey: ['requests', 'mine'],
    queryFn: async () => {
      const [active, history] = await Promise.all([
        requestRepository.getMyActiveJobs(),
        requestRepository.getMyRequestHistory({ limit: 50 }),
      ]);
      return [...active, ...history];
    },
  });
  const [live, setLive] = useState<JobRequest | undefined>(undefined);
  useEffect(() => requestRepository.watchJob(jobId, setLive), [jobId]);

  const categoriesQuery = useQuery({
    queryKey: ['catalog', 'categories'],
    queryFn: () => catalogRepository.getCategories(),
  });

  const job = live ?? mineQuery.data?.find((r) => r.id === jobId);

  if (mineQuery.isPending && live === undefined) {
    return (
      <div className="mx-auto w-full max-w-3xl px-lg py-xxxl">
        <StateBlock variant="loading" />
      </div>
    );
  }
  if (mineQuery.isError) {
    return (
      <div className="mx-auto w-full max-w-3xl px-lg py-xxxl">
        <StateBlock
          variant="error"
          errorMessage={errorText(dict, mineQuery.error)}
          retryLabel={dict.common.retry}
          onRetry={() => void mineQuery.refetch()}
        />
      </div>
    );
  }
  if (!job) {
    return (
      <div className="mx-auto w-full max-w-3xl px-lg py-xxxl">
        <StateBlock
          variant="empty"
          emptyTitle={dict.notFound.title}
          emptyBody={dict.notFound.body}
        />
        <div className="flex justify-center">
          <Link
            href={`/${locale}/requests`}
            className="rounded-md bg-brand-primary px-xl py-sm text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong"
          >
            {dict.common.back}
          </Link>
        </div>
      </div>
    );
  }

  const milestone = milestoneIndex(job.status);
  const allDone = job.status === 'settled' || job.status === 'closed';
  const categories = categoriesQuery.data ?? [];

  return (
    <div className="mx-auto w-full max-w-3xl px-lg py-xxxl">
      <div className="flex flex-wrap items-center justify-between gap-md">
        <h1 className="text-headline-medium text-ink-primary dark:text-ink-dark-primary">
          {dict.requests.detail.title}
        </h1>
        <StatusChip label={statusLabel(dict, job.status)} tone={statusTone(job.status)} />
      </div>

      {milestone !== null ? (
        <div className="mt-xxl">
          <Timeline
            steps={MILESTONE_LABELS.map((key, i) => ({
              label: dict.requests.timeline[key],
              state: allDone || i < milestone ? 'done' : i === milestone ? 'current' : 'pending',
            }))}
          />
        </div>
      ) : null}

      <section className="mt-xxl rounded-lg border border-outline bg-surface-raised p-xl dark:border-outline-dark dark:bg-surface-dark-raised">
        <div className="divide-y divide-outline dark:divide-outline-dark">
          <SummaryRow
            label={dict.newRequest.categoryLabel}
            value={categoryLabel(dict, categories, job.categoryId)}
          />
          <SummaryRow label={dict.requests.detail.pickup} value={job.pickup.label} />
          {job.pickup.landmarkNote ? (
            <SummaryRow
              label={dict.requests.detail.landmark}
              value={job.pickup.landmarkNote}
            />
          ) : null}
          {job.destination ? (
            <SummaryRow
              label={dict.requests.detail.destination}
              value={job.destination.label}
            />
          ) : null}
          <SummaryRow
            label={dict.requests.detail.urgency}
            value={urgencyLabel(dict, job.urgency)}
          />
          {job.scheduledAt ? (
            <SummaryRow
              label={dict.requests.detail.schedule}
              value={formatDateTime(job.scheduledAt)}
            />
          ) : null}
          {job.preferredPrice ? (
            <div className="flex flex-wrap justify-between gap-md py-sm">
              <span className="text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
                {dict.requests.detail.preferredPrice}
              </span>
              <MoneyText
                amountMinor={job.preferredPrice.amountMinor}
                currency={job.preferredPrice.currency}
                className="text-body-medium text-ink-primary dark:text-ink-dark-primary"
              />
            </div>
          ) : null}
          {job.agreedPrice ? (
            <div className="flex flex-wrap justify-between gap-md py-sm">
              <span className="text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
                {dict.requests.detail.agreedPrice}
              </span>
              <MoneyText
                amountMinor={job.agreedPrice.amountMinor}
                currency={job.agreedPrice.currency}
                className="text-body-medium font-semibold text-ink-primary dark:text-ink-dark-primary"
              />
            </div>
          ) : null}
          {job.itemFloat ? (
            <div className="flex flex-wrap justify-between gap-md py-sm">
              <span className="text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
                {dict.requests.detail.itemFloat}
              </span>
              <MoneyText
                amountMinor={job.itemFloat.amountMinor}
                currency={job.itemFloat.currency}
                className="text-body-medium text-ink-primary dark:text-ink-dark-primary"
              />
            </div>
          ) : null}
          {job.declaredValue ? (
            <div className="flex flex-wrap justify-between gap-md py-sm">
              <span className="text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
                {dict.requests.detail.declaredValue}
              </span>
              <MoneyText
                amountMinor={job.declaredValue.amountMinor}
                currency={job.declaredValue.currency}
                className="text-body-medium text-ink-primary dark:text-ink-dark-primary"
              />
            </div>
          ) : null}
        </div>

        <div className="mt-lg">
          <p className="text-label-large text-ink-secondary dark:text-ink-dark-secondary">
            {dict.requests.detail.description}
          </p>
          <p className="mt-xs text-body-large text-ink-primary dark:text-ink-dark-primary">
            {job.description}
          </p>
        </div>

        {job.mediaPaths.length > 0 ? (
          <div className="mt-lg">
            <p className="text-label-large text-ink-secondary dark:text-ink-dark-secondary">
              {dict.requests.detail.photos}
            </p>
            <ul className="mt-xs flex flex-wrap gap-sm">
              {job.mediaPaths.map((path, index) => (
                <li
                  key={`${path}-${index}`}
                  className="rounded-pill border border-outline px-md py-xs text-body-small text-ink-primary dark:border-outline-dark dark:text-ink-dark-primary"
                >
                  {mediaName(path)}
                </li>
              ))}
            </ul>
          </div>
        ) : null}
      </section>

      {job.status === 'draft' ? (
        <DraftPublishSection job={job} locale={locale} dict={dict} />
      ) : null}

      {COLLECTING.has(job.status) ? <OffersBoard job={job} dict={dict} /> : null}

      {job.status === 'agreed' || job.status === 'payment_pending' ? (
        <section className="mt-xxl">
          <Link
            href={`/${locale}/requests/${job.id}/pay`}
            className="inline-block rounded-md bg-brand-primary px-xl py-md text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong"
          >
            {dict.payment.payCta}
          </Link>
          <p className="mt-sm text-body-small text-ink-secondary dark:text-ink-dark-secondary">
            {dict.payment.heldNote}
          </p>
        </section>
      ) : null}

      {IN_CONTACT.has(job.status) ? (
        <section className="mt-xxl flex flex-wrap gap-md">
          <Link
            href={`/${locale}/requests/${job.id}/chat`}
            className="rounded-md bg-brand-primary px-xl py-md text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong"
          >
            {dict.chat.title}
          </Link>
          <Link
            href={`/${locale}/requests/${job.id}/track`}
            className="rounded-md border border-outline px-xl py-md text-label-large text-ink-primary transition-colors duration-normal ease-standard hover:bg-surface-muted dark:border-outline-dark dark:text-ink-dark-primary dark:hover:bg-surface-dark-muted"
          >
            {dict.tracking.title}
          </Link>
        </section>
      ) : null}

      {job.handoverPin && milestone !== null && milestone >= 2 ? (
        <div className="mt-xxl">
          <HandoverPinCard pin={job.handoverPin} dict={dict} />
        </div>
      ) : null}

      {job.status === 'completed_by_provider' ? (
        <ConfirmCompletionSection job={job} dict={dict} />
      ) : null}

      {RATEABLE.has(job.status) ? (
        <section className="mt-xxl">
          <div className="mt-lg">
            <RatingSheet jobId={job.id} dict={dict} />
          </div>
        </section>
      ) : null}

      {DISPUTABLE.has(job.status) ? <DisputeSection jobId={job.id} dict={dict} /> : null}

      {CANCELLABLE.has(job.status) ? (
        <section className="mt-xxl">
          <CancelRequestButton jobId={job.id} dict={dict} />
        </section>
      ) : null}
    </div>
  );
}
