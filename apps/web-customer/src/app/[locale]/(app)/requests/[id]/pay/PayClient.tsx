'use client';

import { useEffect, useState } from 'react';
import Link from 'next/link';
import { useQuery } from '@tanstack/react-query';
import type { Dictionary } from '@/lib/i18n/en';
import type { Locale } from '@/lib/i18n';
import { newIdempotencyKey } from '@/lib/idempotency';
import { serverClockOffsetMs } from '@/lib/serverClock';
import { isAppError, paymentRepository, requestRepository } from '@/lib/repositories';
import type {
  JobRequest,
  JobStatus,
  Payment,
  PaymentMethod,
  PaymentSession,
} from '@/mocks/types';
import { CountdownTimer } from '@/components/CountdownTimer';
import { MoneyText } from '@/components/MoneyText';
import { StateBlock } from '@/components/StateBlock';
import { StatusChip } from '@/components/StatusChip';
import { errorText, statusLabel, statusTone } from '../../_shared';

const METHODS: readonly PaymentMethod[] = ['card', 'bank_transfer', 'mobile_money', 'ussd'];

/** initializePayment is only valid in these states (first attempt / TTL retry). */
const PAYABLE: ReadonlySet<JobStatus> = new Set(['agreed', 'payment_pending']);

/** Baseline fetch (resolves unknown ids) + live updates via watchJob. */
function useJob(jobId: string) {
  const query = useQuery({
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
  return { query, job: live ?? query.data?.find((r) => r.id === jobId) };
}

function MethodPicker({
  dict,
  method,
  onChange,
}: {
  dict: Dictionary;
  method: PaymentMethod;
  onChange: (method: PaymentMethod) => void;
}) {
  return (
    <fieldset>
      <legend className="text-label-large text-ink-secondary dark:text-ink-dark-secondary">
        {dict.payment.methodTitle}
      </legend>
      <div className="mt-sm grid grid-cols-2 gap-md">
        {METHODS.map((m) => (
          <label
            key={m}
            className={`flex cursor-pointer items-center gap-sm rounded-md border px-lg py-md text-body-large transition-colors duration-normal ease-standard ${
              method === m
                ? 'border-brand-primary bg-brand-primary/10 text-ink-primary dark:border-brand-secondary dark:text-ink-dark-primary'
                : 'border-outline text-ink-primary hover:bg-surface-muted dark:border-outline-dark dark:text-ink-dark-primary dark:hover:bg-surface-dark-muted'
            }`}
          >
            <input
              type="radio"
              name="payment-method"
              value={m}
              checked={method === m}
              onChange={() => onChange(m)}
              className="accent-brand-primary"
            />
            {dict.payment.methods[m]}
          </label>
        ))}
      </div>
    </fieldset>
  );
}

export function PayClient({
  locale,
  jobId,
  dict,
}: {
  locale: Locale;
  jobId: string;
  dict: Dictionary;
}) {
  const { query, job } = useJob(jobId);

  const [payment, setPayment] = useState<Payment | undefined>(undefined);
  useEffect(() => paymentRepository.watchPaymentForJob(jobId, setPayment), [jobId]);

  // One idempotency key per payment intent: reused on retry, regenerated
  // after success or when the chosen method changes.
  const [method, setMethod] = useState<PaymentMethod>('card');
  const [payKey, setPayKey] = useState(() => newIdempotencyKey());
  const [session, setSession] = useState<PaymentSession | undefined>(undefined);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [verificationRequired, setVerificationRequired] = useState(false);

  const pickMethod = (m: PaymentMethod) => {
    if (m !== method) {
      setMethod(m);
      setPayKey(newIdempotencyKey());
    }
  };

  const pay = async () => {
    setBusy(true);
    setError(null);
    try {
      const result = await paymentRepository.initializePayment({
        jobId,
        method,
        idempotencyKey: payKey,
      });
      setSession(result);
      setPayKey(newIdempotencyKey());
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

  if (query.isPending && job === undefined) {
    return (
      <div className="mx-auto w-full max-w-3xl px-lg py-xxxl">
        <StateBlock variant="loading" />
      </div>
    );
  }
  if (query.isError) {
    return (
      <div className="mx-auto w-full max-w-3xl px-lg py-xxxl">
        <StateBlock
          variant="error"
          errorMessage={errorText(dict, query.error)}
          retryLabel={dict.common.retry}
          onRetry={() => void query.refetch()}
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

  // Server-computed amount only — the agreed breakdown/quote, never derived here.
  const amount = payment?.amount ?? job.agreedBreakdown?.gross ?? job.agreedPrice;
  const backLink = (
    <Link
      href={`/${locale}/requests/${job.id}`}
      className="text-label-large text-brand-primary hover:underline dark:text-brand-secondary"
    >
      {dict.common.back}
    </Link>
  );

  const header = (
    <div className="flex flex-wrap items-center justify-between gap-md">
      <h1 className="text-headline-medium text-ink-primary dark:text-ink-dark-primary">
        {dict.payment.title}
      </h1>
      <StatusChip label={statusLabel(dict, job.status)} tone={statusTone(job.status)} />
    </div>
  );

  // --- Success: webhook flipped payment HELD and the job to PAID_HELD. ---
  if (payment?.status === 'held' || job.status === 'paid_held') {
    return (
      <div className="mx-auto w-full max-w-3xl px-lg py-xxxl">
        {header}
        <section className="mt-xxl rounded-lg border border-success bg-success/10 p-xl text-center dark:border-success-dark dark:bg-success-dark/20">
          <h2 className="text-title-large text-success dark:text-success-dark">
            {dict.payment.successTitle}
          </h2>
          <p className="mt-sm text-body-large text-ink-primary dark:text-ink-dark-primary">
            {dict.payment.successBody}
          </p>
          {amount ? (
            <MoneyText
              amountMinor={amount.amountMinor}
              currency={amount.currency}
              className="mt-md block text-headline-medium text-ink-primary dark:text-ink-dark-primary"
            />
          ) : null}
          <p className="mt-md text-body-small text-ink-secondary dark:text-ink-dark-secondary">
            {dict.payment.heldNote}
          </p>
          <div className="mt-lg">{backLink}</div>
        </section>
      </div>
    );
  }

  // --- Failure: declined or TTL-expired; the job is back to AGREED. ---
  if (payment?.status === 'failed') {
    return (
      <div className="mx-auto w-full max-w-3xl px-lg py-xxxl">
        {header}
        <section className="mt-xxl rounded-lg border border-error bg-error/10 p-xl dark:border-error-dark dark:bg-error-dark/20">
          <h2 className="text-title-large text-error dark:text-error-dark">
            {dict.payment.failureTitle}
          </h2>
          <p className="mt-sm text-body-large text-ink-primary dark:text-ink-dark-primary">
            {dict.payment.failureBody}
          </p>
        </section>
        <section className="mt-xxl rounded-lg border border-outline bg-surface-raised p-xl dark:border-outline-dark dark:bg-surface-dark-raised">
          {amount ? (
            <div className="mb-lg flex flex-wrap items-center justify-between gap-md">
              <span className="text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
                {dict.payment.amountDue}
              </span>
              <MoneyText
                amountMinor={amount.amountMinor}
                currency={amount.currency}
                className="text-title-large text-ink-primary dark:text-ink-dark-primary"
              />
            </div>
          ) : null}
          <MethodPicker dict={dict} method={method} onChange={pickMethod} />
          <button
            type="button"
            disabled={busy}
            onClick={() => void pay()}
            className="mt-lg w-full rounded-md bg-brand-primary px-xl py-md text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong disabled:opacity-50"
          >
            {dict.payment.tryAgain}
          </button>
          {error ? (
            <p role="alert" className="mt-sm text-body-small text-error dark:text-error-dark">
              {error}
            </p>
          ) : null}
        </section>
        <div className="mt-lg">{backLink}</div>
      </div>
    );
  }

  // --- Pending: waiting on the simulated gateway webhook within the TTL. ---
  if (payment?.status === 'pending') {
    const reference = session?.reference ?? payment.gatewayReference;
    return (
      <div className="mx-auto w-full max-w-3xl px-lg py-xxxl">
        {header}
        <section className="mt-xxl rounded-lg border border-outline bg-surface-raised p-xl text-center dark:border-outline-dark dark:bg-surface-dark-raised">
          {amount ? (
            <MoneyText
              amountMinor={amount.amountMinor}
              currency={amount.currency}
              className="block text-headline-medium text-ink-primary dark:text-ink-dark-primary"
            />
          ) : null}
          <p className="mt-md text-body-large text-ink-primary dark:text-ink-dark-primary">
            {dict.payment.waiting}
          </p>
          {payment.expiresAt ? (
            <p className="mt-md text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
              {dict.payment.ttlLabel}{' '}
              <CountdownTimer
                deadline={payment.expiresAt.toISOString()}
                clockOffsetMs={serverClockOffsetMs()}
                expiredLabel={dict.payment.failureTitle}
                className="font-semibold text-warning dark:text-warning-dark"
              />
            </p>
          ) : null}
          {payment.method === 'ussd' ? (
            <div className="mt-lg rounded-md bg-surface-muted p-lg dark:bg-surface-dark-muted">
              <p className="text-label-large text-ink-secondary dark:text-ink-dark-secondary">
                {dict.payment.ussdInstructionLabel}
              </p>
              {session?.ussdCode ? (
                <p className="mt-xs text-title-large text-ink-primary dark:text-ink-dark-primary">
                  {session.ussdCode}
                </p>
              ) : null}
              <p className="mt-xs text-body-small text-ink-secondary dark:text-ink-dark-secondary">
                {dict.payment.ussdInstructionHint}
              </p>
            </div>
          ) : null}
          {payment.method === 'bank_transfer' ? (
            <div className="mt-lg rounded-md bg-surface-muted p-lg text-left dark:bg-surface-dark-muted">
              <p className="text-label-large text-ink-secondary dark:text-ink-dark-secondary">
                {dict.payment.transferInstructionLabel}
              </p>
              <p className="mt-xs text-body-small text-ink-secondary dark:text-ink-dark-secondary">
                {dict.payment.transferInstructionHint}
              </p>
              {reference ? (
                <p className="mt-sm text-body-medium text-ink-primary dark:text-ink-dark-primary">
                  {dict.payment.transferReferenceLabel}: {reference}
                </p>
              ) : null}
            </div>
          ) : null}
        </section>
        <div className="mt-lg">{backLink}</div>
      </div>
    );
  }

  // --- Checkout: amount + method picker + pay CTA. ---
  return (
    <div className="mx-auto w-full max-w-3xl px-lg py-xxxl">
      {header}
      <section className="mt-xxl rounded-lg border border-outline bg-surface-raised p-xl dark:border-outline-dark dark:bg-surface-dark-raised">
        {amount ? (
          <div className="mb-lg flex flex-wrap items-center justify-between gap-md">
            <span className="text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
              {dict.payment.amountDue}
            </span>
            <MoneyText
              amountMinor={amount.amountMinor}
              currency={amount.currency}
              className="text-title-large text-ink-primary dark:text-ink-dark-primary"
            />
          </div>
        ) : null}
        <p className="mb-lg text-body-small text-ink-secondary dark:text-ink-dark-secondary">
          {dict.payment.heldNote}
        </p>
        {verificationRequired ? (
          <div className="rounded-md border border-warning bg-warning/10 p-lg dark:border-warning-dark dark:bg-warning-dark/20">
            <p className="text-body-medium text-ink-primary dark:text-ink-dark-primary">
              {dict.errors.ERR_VERIFICATION_REQUIRED}
            </p>
            <Link
              href={`/${locale}/verify`}
              className="mt-sm inline-block rounded-md bg-brand-primary px-lg py-sm text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong"
            >
              {dict.verify.title}
            </Link>
          </div>
        ) : (
          <>
            <MethodPicker dict={dict} method={method} onChange={pickMethod} />
            <button
              type="button"
              disabled={busy || !PAYABLE.has(job.status)}
              onClick={() => void pay()}
              className="mt-lg w-full rounded-md bg-brand-primary px-xl py-md text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong disabled:opacity-50"
            >
              {dict.payment.payCta}
            </button>
          </>
        )}
        {error ? (
          <p role="alert" className="mt-sm text-body-small text-error dark:text-error-dark">
            {error}
          </p>
        ) : null}
      </section>
      <div className="mt-lg">{backLink}</div>
    </div>
  );
}
