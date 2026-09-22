'use client';

import { useEffect, useRef, useState, type ReactNode } from 'react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { dict } from '@/lib/i18n';
import { newIdempotencyKey } from '@/lib/idempotency';
import { disputeRepository, isAppError, sessionRepository } from '@/mocks/repositories';
import type {
  DisputeCase,
  DisputeResolutionAction,
  DisputeResolutionQuote,
} from '@/mocks/types';
import { MoneyText } from '@/components/MoneyText';
import { ReauthModal } from '@/components/ReauthModal';
import { StateBlock } from '@/components/StateBlock';
import { can, errorText, formatDateTime, isSessionError, useAdminSession } from '../../_shared';
import {
  disputeReasonLabel,
  disputeStatusChip,
  quoteLineLabel,
  resolutionActionLabel,
} from '../_shared';

const ACTIONS: DisputeResolutionAction[] = [
  'refund_full',
  'refund_partial',
  'release_to_provider',
  'reject',
];

const inputClass =
  'w-full rounded-md border border-outline bg-surface px-md py-sm text-body-large text-ink-primary outline-none transition-colors duration-normal ease-standard focus:border-brand-primary dark:border-outline-dark dark:bg-surface-dark dark:text-ink-dark-primary';

const cardClass =
  'rounded-lg border border-outline bg-surface-raised p-lg dark:border-outline-dark dark:bg-surface-dark-raised';

function DetailRow({ label, value }: { label: string; value: ReactNode }) {
  return (
    <div className="flex flex-wrap justify-between gap-md py-sm">
      <span className="text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
        {label}
      </span>
      <span className="text-body-medium text-ink-primary dark:text-ink-dark-primary">{value}</span>
    </div>
  );
}

function uploadedByLabel(uploadedBy: 'customer' | 'provider' | 'system'): string {
  return dict.disputes.detail.evidence.uploadedBy[uploadedBy];
}

function QuoteCard({ quote }: { quote: DisputeResolutionQuote }) {
  return (
    <div className="flex flex-col gap-sm">
      <h3 className="text-title-large text-ink-primary dark:text-ink-dark-primary">
        {dict.disputes.detail.quoteCardTitle}
      </h3>
      <p className="text-body-small text-ink-secondary dark:text-ink-dark-secondary">
        {dict.disputes.detail.quoteServerNote}
      </p>
      <div className="divide-y divide-outline rounded-lg border border-outline px-lg dark:divide-outline-dark dark:border-outline-dark">
        <DetailRow
          label={quoteLineLabel('refundToCustomer')}
          value={
            <MoneyText
              amountMinor={quote.refundToCustomer.amountMinor}
              currency={quote.refundToCustomer.currency}
            />
          }
        />
        <DetailRow
          label={quoteLineLabel('releaseToProvider')}
          value={
            <MoneyText
              amountMinor={quote.releaseToProvider.amountMinor}
              currency={quote.releaseToProvider.currency}
            />
          }
        />
        <DetailRow
          label={quoteLineLabel('platformRetained')}
          value={
            <MoneyText
              amountMinor={quote.platformRetained.amountMinor}
              currency={quote.platformRetained.currency}
            />
          }
        />
      </div>
    </div>
  );
}

function ResolutionSection({ dispute }: { dispute: DisputeCase }) {
  const router = useRouter();
  const queryClient = useQueryClient();
  const sessionQuery = useAdminSession();
  const role = sessionQuery.data?.admin.role;
  const mayResolve = role !== undefined && can(role, 'disputes.resolve');

  const [action, setAction] = useState<DisputeResolutionAction>('refund_full');
  const [percent, setPercent] = useState('50');
  const [note, setNote] = useState('');
  const pct = action === 'refund_partial' ? Number(percent) : undefined;

  // Server-computed quote for the currently chosen action — display only.
  const quoteQuery = useQuery({
    queryKey: ['disputes', 'quote', dispute.id, action, pct],
    queryFn: () => disputeRepository.getResolutionQuote(dispute.id, action, pct),
    enabled: mayResolve,
  });

  const [busy, setBusy] = useState(false);
  const [actionError, setActionError] = useState<string | null>(null);
  // One key per (action, percent) resolve intent; kept across the reauth
  // retry, deleted after success so a later resolve is a fresh intent.
  const intentKeys = useRef<Record<string, string>>({});
  const keyFor = (name: string) => (intentKeys.current[name] ??= newIdempotencyKey());

  const [reauthOpen, setReauthOpen] = useState(false);
  const [reauthError, setReauthError] = useState<string | null>(null);
  const pendingAction = useRef<(() => Promise<void>) | null>(null);

  const runAction = async (fn: () => Promise<unknown>, options?: { onSuccess?: () => void }) => {
    setBusy(true);
    setActionError(null);
    try {
      await fn();
      options?.onSuccess?.();
      void queryClient.invalidateQueries({ queryKey: ['disputes'] });
    } catch (e) {
      if (isAppError(e, 'ERR_REAUTH_REQUIRED')) {
        // Sensitive action: re-authenticate, then retry with the SAME key.
        pendingAction.current = () => runAction(fn, options);
        setReauthError(null);
        setReauthOpen(true);
      } else if (isSessionError(e)) {
        router.replace('/sign-in');
      } else {
        setActionError(errorText(e));
      }
    } finally {
      setBusy(false);
    }
  };

  const confirmReauth = async (_code: string) => {
    // The mock reauth records the purpose in the audit log; the authenticator
    // code itself is not verified at this layer.
    try {
      await sessionRepository.reauth('disputes.resolve');
      setReauthOpen(false);
      const next = pendingAction.current;
      pendingAction.current = null;
      if (next) await next();
    } catch (e) {
      if (isSessionError(e)) {
        router.replace('/sign-in');
      } else {
        setReauthError(errorText(e));
      }
    }
  };

  if (dispute.resolution) {
    const { resolution } = dispute;
    return (
      <section className={`${cardClass} flex flex-col gap-md`}>
        <div className="flex flex-wrap items-center gap-md">
          {disputeStatusChip(dispute.status)}
          <span className="text-body-large text-ink-primary dark:text-ink-dark-primary">
            {resolutionActionLabel(resolution.action)}
          </span>
        </div>
        <p className="text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
          {dict.disputes.detail.resolvedNote}
        </p>
        <QuoteCard quote={resolution.quote} />
        <div className="divide-y divide-outline dark:divide-outline-dark">
          <DetailRow label={dict.payments.approval.approvedBy} value={resolution.byAdminId} />
          <DetailRow label={dict.audit.columns.time} value={formatDateTime(resolution.at)} />
        </div>
      </section>
    );
  }

  if (!mayResolve) return null;

  const intentName = `resolve:${dispute.id}:${action}:${pct ?? ''}`;

  const resolve = () =>
    runAction(
      () =>
        disputeRepository.resolveDispute(
          dispute.id,
          action,
          { partialPercent: pct, note: note.trim() === '' ? undefined : note.trim() },
          keyFor(intentName),
        ),
      {
        onSuccess: () => {
          delete intentKeys.current[intentName];
          setNote('');
        },
      },
    );

  return (
    <section className={`${cardClass} flex flex-col gap-lg`}>
      <h3 className="text-title-large text-ink-primary dark:text-ink-dark-primary">
        {dict.disputes.detail.quoteCardTitle}
      </h3>

      <div className="flex flex-col gap-xs">
        <label
          htmlFor="resolution-action"
          className="text-label-large text-ink-primary dark:text-ink-dark-primary"
        >
          {dict.common.actions}
        </label>
        <select
          id="resolution-action"
          value={action}
          onChange={(e) => setAction(e.target.value as DisputeResolutionAction)}
          className={inputClass}
        >
          {ACTIONS.map((a) => (
            <option key={a} value={a}>
              {resolutionActionLabel(a)}
            </option>
          ))}
        </select>
      </div>

      {action === 'refund_partial' ? (
        <div className="flex flex-col gap-xs">
          <label
            htmlFor="resolution-percent"
            className="text-label-large text-ink-primary dark:text-ink-dark-primary"
          >
            {dict.disputes.detail.partialAmountLabel}
          </label>
          <input
            id="resolution-percent"
            type="number"
            min={1}
            max={99}
            value={percent}
            onChange={(e) => setPercent(e.target.value)}
            className={inputClass}
          />
        </div>
      ) : null}

      {quoteQuery.isPending ? (
        <StateBlock variant="loading" />
      ) : quoteQuery.isError ? (
        <p role="alert" className="text-body-small text-error dark:text-error-dark">
          {errorText(quoteQuery.error)}
        </p>
      ) : (
        <QuoteCard quote={quoteQuery.data} />
      )}

      <div className="flex flex-col gap-xs">
        <label
          htmlFor="resolution-note"
          className="text-label-large text-ink-primary dark:text-ink-dark-primary"
        >
          {dict.common.reason}
        </label>
        <textarea
          id="resolution-note"
          rows={3}
          value={note}
          onChange={(e) => setNote(e.target.value)}
          placeholder={dict.common.reasonPlaceholder}
          className={inputClass}
        />
      </div>

      {actionError ? (
        <p role="alert" className="text-body-small text-error dark:text-error-dark">
          {actionError}
        </p>
      ) : null}

      <div>
        <button
          type="button"
          disabled={busy || quoteQuery.isError}
          onClick={() => void resolve()}
          className="rounded-md bg-brand-primary px-xl py-sm text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong disabled:opacity-50"
        >
          {dict.disputes.detail.resolveCta}
        </button>
      </div>

      <ReauthModal
        open={reauthOpen}
        onClose={() => setReauthOpen(false)}
        onConfirm={(code) => void confirmReauth(code)}
        title={dict.auth.reauth.title}
        body={dict.auth.reauth.body}
        codeLabel={dict.auth.mfaCodeLabel}
        confirmLabel={dict.auth.reauth.confirmCta}
        cancelLabel={dict.common.cancel}
        error={reauthError ?? undefined}
      />
    </section>
  );
}

export function DisputeDetailClient({ disputeId }: { disputeId: string }) {
  const router = useRouter();
  const sessionQuery = useAdminSession();
  const role = sessionQuery.data?.admin.role;
  const mayRead = role !== undefined && can(role, 'disputes.read');

  const disputeQuery = useQuery({
    queryKey: ['disputes', 'detail', disputeId],
    queryFn: () => disputeRepository.getDispute(disputeId),
    enabled: mayRead,
  });

  useEffect(() => {
    if (disputeQuery.error && isSessionError(disputeQuery.error)) router.replace('/sign-in');
  }, [disputeQuery.error, router]);

  if (sessionQuery.isPending) {
    return <StateBlock variant="loading" />;
  }
  if (!mayRead) {
    return <StateBlock variant="error" errorMessage={dict.errors.ERR_PERMISSION_DENIED} />;
  }

  const dispute = disputeQuery.data;

  return (
    <div className="flex flex-col gap-xl">
      <Link
        href="/disputes"
        className="text-body-small text-brand-primary underline-offset-2 transition-colors duration-normal ease-standard hover:underline dark:text-brand-secondary"
      >
        ← {dict.common.back}
      </Link>

      {disputeQuery.isPending ? (
        <StateBlock variant="loading" />
      ) : disputeQuery.isError ? (
        <StateBlock
          variant="error"
          errorMessage={errorText(disputeQuery.error)}
          retryLabel={dict.common.retry}
          onRetry={() => void disputeQuery.refetch()}
        />
      ) : dispute ? (
        <>
          <div className="flex flex-wrap items-center gap-md">
            <h1 className="text-headline-medium text-ink-primary dark:text-ink-dark-primary">
              {dispute.id}
            </h1>
            {disputeStatusChip(dispute.status)}
          </div>

          <section className={cardClass}>
            <h2 className="text-title-large text-ink-primary dark:text-ink-dark-primary">
              {dict.disputes.detail.partiesTitle}
            </h2>
            <div className="mt-sm divide-y divide-outline dark:divide-outline-dark">
              <DetailRow label={dict.jobs.columns.customer} value={dispute.customerName} />
              <DetailRow label={dict.jobs.columns.provider} value={dispute.providerName} />
              <DetailRow
                label={dict.disputes.columns.job}
                value={
                  <Link
                    href={`/jobs/${dispute.jobId}`}
                    className="text-brand-primary underline-offset-2 transition-colors duration-normal ease-standard hover:underline dark:text-brand-secondary"
                  >
                    {dispute.jobId}
                  </Link>
                }
              />
              <DetailRow
                label={dict.disputes.columns.reason}
                value={disputeReasonLabel(dispute.reasonKey)}
              />
              <DetailRow
                label={dict.payments.columns.amount}
                value={
                  <MoneyText
                    amountMinor={dispute.heldAmount.amountMinor}
                    currency={dispute.heldAmount.currency}
                  />
                }
              />
              <DetailRow
                label={dict.audit.columns.time}
                value={formatDateTime(dispute.openedAt)}
              />
              {dispute.assignedToAdminId ? (
                <DetailRow
                  label={dict.support.columns.assigned}
                  value={dispute.assignedToAdminId}
                />
              ) : null}
            </div>
          </section>

          <section className={cardClass}>
            <h2 className="text-title-large text-ink-primary dark:text-ink-dark-primary">
              {dict.disputes.detail.evidenceTitle}
            </h2>
            <p className="mt-xs text-body-small text-ink-secondary dark:text-ink-dark-secondary">
              {dict.disputes.detail.evidenceMockNote}
            </p>
            {dispute.evidence.length === 0 ? (
              <p className="mt-md text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
                {dict.common.emptyGeneric}
              </p>
            ) : (
              <ul className="mt-md grid gap-md sm:grid-cols-2">
                {dispute.evidence.map((ev) => (
                  <li
                    key={ev.id}
                    className="flex flex-col gap-xs rounded-md border border-outline bg-surface-muted p-md dark:border-outline-dark dark:bg-surface-dark-muted"
                  >
                    <span className="text-body-large text-ink-primary dark:text-ink-dark-primary">
                      {ev.label}
                    </span>
                    <span className="text-body-small text-ink-secondary dark:text-ink-dark-secondary">
                      {ev.kind} · {uploadedByLabel(ev.uploadedBy)} ·{' '}
                      {formatDateTime(ev.uploadedAt)}
                    </span>
                  </li>
                ))}
              </ul>
            )}
          </section>

          <ResolutionSection dispute={dispute} />
        </>
      ) : null}
    </div>
  );
}
