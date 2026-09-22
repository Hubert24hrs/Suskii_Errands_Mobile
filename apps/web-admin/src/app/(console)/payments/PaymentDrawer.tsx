'use client';

import { useEffect, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { dict } from '@/lib/i18n';
import { newIdempotencyKey } from '@/lib/idempotency';
import {
  isAppError,
  paymentsRepository,
  sessionRepository,
} from '@/mocks/repositories';
import type { PaymentAdminView } from '@/mocks/types';
import { Drawer } from '@/components/Drawer';
import { MoneyText } from '@/components/MoneyText';
import { ReauthModal } from '@/components/ReauthModal';
import { StateBlock } from '@/components/StateBlock';
import { can, errorText, formatDateTime, isSessionError, useAdminSession } from '../_shared';
import { kindLabel, paymentStatusChip } from './_shared';

function DetailRow({ label, value }: { label: string; value: string }) {
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
    <div className="flex flex-wrap justify-between gap-md py-sm">
      <span className="text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
        {label}
      </span>
      <MoneyText
        amountMinor={amountMinor}
        currency={currency}
        className="text-body-medium text-ink-primary dark:text-ink-dark-primary"
      />
    </div>
  );
}

export function PaymentDrawer({
  paymentId,
  onClose,
}: {
  paymentId: string | null;
  onClose: () => void;
}) {
  const router = useRouter();
  const queryClient = useQueryClient();
  const sessionQuery = useAdminSession();
  const role = sessionQuery.data?.admin.role;
  const adminId = sessionQuery.data?.admin.id;
  const mayApprove = role !== undefined && can(role, 'payments.approve');

  const paymentQuery = useQuery({
    queryKey: ['payments', 'detail', paymentId],
    queryFn: () => paymentsRepository.getPayment(paymentId!),
    enabled: paymentId !== null && mayApprove !== undefined,
  });

  const [busy, setBusy] = useState(false);
  const [actionError, setActionError] = useState<string | null>(null);
  const [sameApprover, setSameApprover] = useState(false);
  const [rejectOpen, setRejectOpen] = useState(false);
  const [rejectReason, setRejectReason] = useState('');
  const [rejectKey, setRejectKey] = useState(() => newIdempotencyKey());

  // One key per (action, payment) intent; kept across the reauth retry,
  // deleted after success so a later action is a fresh intent.
  const intentKeys = useRef<Record<string, string>>({});
  const keyFor = (name: string) => (intentKeys.current[name] ??= newIdempotencyKey());

  const [reauthOpen, setReauthOpen] = useState(false);
  const [reauthError, setReauthError] = useState<string | null>(null);
  const pendingAction = useRef<(() => Promise<void>) | null>(null);

  useEffect(() => {
    if (paymentQuery.error && isSessionError(paymentQuery.error)) {
      router.replace('/sign-in');
    }
  }, [paymentQuery.error, router]);

  const refresh = () => void queryClient.invalidateQueries({ queryKey: ['payments'] });

  const runAction = async (
    fn: () => Promise<unknown>,
    options?: { onSuccess?: () => void; sameApproverOnInvalidState?: boolean },
  ) => {
    setBusy(true);
    setActionError(null);
    setSameApprover(false);
    try {
      await fn();
      options?.onSuccess?.();
      refresh();
    } catch (e) {
      if (isAppError(e, 'ERR_REAUTH_REQUIRED')) {
        // Sensitive action: re-authenticate, then retry with the SAME key.
        pendingAction.current = () => runAction(fn, options);
        setReauthError(null);
        setReauthOpen(true);
      } else if (isSessionError(e)) {
        router.replace('/sign-in');
      } else if (isAppError(e, 'ERR_INVALID_STATE') && options?.sameApproverOnInvalidState) {
        // confirmApproval refuses a second approver equal to the first.
        setSameApprover(true);
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
      await sessionRepository.reauth('payments.approve');
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

  const payment = paymentQuery.data;
  const actionable =
    payment !== undefined && payment.kind === 'withdrawal' && payment.status === 'pending';

  const approve = (id: string) =>
    runAction(
      async () => {
        try {
          return await paymentsRepository.approveWithdrawal(id, keyFor(`approve:${id}`));
        } catch (e) {
          // Above the two-person threshold the direct approve is refused;
          // the same click becomes a requestApproval, moving the payment to
          // awaiting_second (a different admin then confirms). requestApproval
          // is itself sensitive — an ERR_REAUTH_REQUIRED propagates to the
          // runAction reauth flow and retries with the SAME keys.
          if (isAppError(e, 'ERR_APPROVAL_REQUIRED')) {
            return await paymentsRepository.requestApproval(id, keyFor(`request:${id}`));
          }
          throw e;
        }
      },
      {
        onSuccess: () => {
          delete intentKeys.current[`approve:${id}`];
          delete intentKeys.current[`request:${id}`];
        },
      },
    );

  const confirm = (id: string) =>
    runAction(() => paymentsRepository.confirmApproval(id, keyFor(`confirm:${id}`)), {
      sameApproverOnInvalidState: true,
      onSuccess: () => {
        delete intentKeys.current[`confirm:${id}`];
      },
    });

  const reject = (id: string) =>
    runAction(() => paymentsRepository.rejectApproval(id, rejectReason.trim(), rejectKey), {
      onSuccess: () => {
        setRejectKey(newIdempotencyKey());
        setRejectOpen(false);
        setRejectReason('');
      },
    });

  const buttonClass =
    'rounded-md px-xl py-sm text-label-large transition-colors duration-normal ease-standard disabled:opacity-50';
  const primaryButton = `${buttonClass} bg-brand-primary text-brand-on-primary hover:bg-brand-primary-strong`;
  const dangerButton = `${buttonClass} border border-error text-error hover:bg-error/10 dark:border-error-dark dark:text-error-dark dark:hover:bg-error-dark/20`;

  const approvalSection = (p: PaymentAdminView) => {
    const { approval } = p;
    if (approval.state === 'none') return null;

    if (approval.state === 'approved') {
      return (
        <section className="rounded-lg border border-outline bg-surface-raised p-lg dark:border-outline-dark dark:bg-surface-dark-raised">
          <DetailRow
            label={dict.payments.approval.approvedBy}
            value={approval.approverIds.join(', ')}
          />
          {approval.decidedAt ? (
            <DetailRow label={dict.jobs.columns.updated} value={formatDateTime(approval.decidedAt)} />
          ) : null}
        </section>
      );
    }

    if (approval.state === 'awaiting_second') {
      const iAmFirstApprover = adminId !== undefined && approval.approverIds.includes(adminId);
      return (
        <section className="flex flex-col gap-md rounded-lg border border-outline bg-surface-raised p-lg dark:border-outline-dark dark:bg-surface-dark-raised">
          <DetailRow
            label={dict.payments.approval.approvedBy}
            value={approval.approverIds[0] ?? '—'}
          />
          <p className="text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
            {dict.payments.approval.awaitingSecondApprover}
          </p>
          <p className="text-body-small text-ink-secondary dark:text-ink-dark-secondary">
            {dict.payments.approval.twoPersonNote}
          </p>
          {mayApprove && actionable ? (
            iAmFirstApprover ? (
              <p className="text-body-small text-warning dark:text-warning-dark">
                {dict.payments.approval.sameApproverNote}
              </p>
            ) : (
              <div className="flex flex-wrap gap-md">
                <button
                  type="button"
                  disabled={busy}
                  onClick={() => void confirm(p.id)}
                  className={primaryButton}
                >
                  {dict.payments.approval.approveCta}
                </button>
                <button
                  type="button"
                  disabled={busy}
                  onClick={() => {
                    setRejectKey(newIdempotencyKey());
                    setRejectOpen(true);
                  }}
                  className={dangerButton}
                >
                  {dict.payments.approval.rejectCta}
                </button>
              </div>
            )
          ) : null}
        </section>
      );
    }

    if (approval.state === 'single_pending') {
      return (
        <section className="flex flex-col gap-md rounded-lg border border-outline bg-surface-raised p-lg dark:border-outline-dark dark:bg-surface-dark-raised">
          <p className="text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
            {dict.payments.approval.singleApproval}
          </p>
          {mayApprove && actionable ? (
            <div className="flex flex-wrap gap-md">
              <button
                type="button"
                disabled={busy}
                onClick={() => void approve(p.id)}
                className={primaryButton}
              >
                {dict.payments.approval.approveCta}
              </button>
              <button
                type="button"
                disabled={busy}
                onClick={() => {
                  setRejectKey(newIdempotencyKey());
                  setRejectOpen(true);
                }}
                className={dangerButton}
              >
                {dict.payments.approval.rejectCta}
              </button>
            </div>
          ) : null}
        </section>
      );
    }

    // rejected
    return (
      <section className="rounded-lg border border-outline bg-surface-raised p-lg dark:border-outline-dark dark:bg-surface-dark-raised">
        <DetailRow
          label={dict.payments.approval.rejectCta}
          value={approval.rejectedByAdminId ?? '—'}
        />
        {approval.decidedAt ? (
          <DetailRow label={dict.jobs.columns.updated} value={formatDateTime(approval.decidedAt)} />
        ) : null}
      </section>
    );
  };

  return (
    <Drawer
      open={paymentId !== null}
      onClose={onClose}
      title={payment?.id ?? ''}
      closeLabel={dict.common.close}
    >
      {paymentQuery.isPending ? (
        <StateBlock variant="loading" />
      ) : paymentQuery.isError ? (
        <StateBlock
          variant="error"
          errorMessage={errorText(paymentQuery.error)}
          retryLabel={dict.common.retry}
          onRetry={() => void paymentQuery.refetch()}
        />
      ) : payment ? (
        <div className="flex flex-col gap-lg">
          <div className="flex items-center gap-md">
            {paymentStatusChip(payment.status)}
            <span className="text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
              {kindLabel(payment.kind)}
            </span>
          </div>

          <div className="divide-y divide-outline dark:divide-outline-dark">
            <DetailRow label={dict.payments.columns.user} value={payment.counterpartyName} />
            <DetailRow label={dict.jobs.columns.id} value={payment.referenceId} />
            <DetailRow
              label={dict.directory.columns.country}
              value={
                (dict.dashboard.countries as Record<string, string>)[payment.country] ??
                payment.country
              }
            />
            <DetailRow label={dict.audit.columns.time} value={formatDateTime(payment.createdAt)} />
          </div>

          {/* Server quote object — displayed, never derived. */}
          <div className="divide-y divide-outline rounded-lg border border-outline px-lg dark:divide-outline-dark dark:border-outline-dark">
            <MoneyRow
              label={dict.payments.detail.gross}
              amountMinor={payment.quote.gross.amountMinor}
              currency={payment.quote.gross.currency}
            />
            {payment.quote.platformCommission ? (
              <MoneyRow
                label={dict.payments.detail.commission}
                amountMinor={payment.quote.platformCommission.amountMinor}
                currency={payment.quote.platformCommission.currency}
              />
            ) : null}
            <MoneyRow
              label={dict.payments.detail.net}
              amountMinor={payment.quote.net.amountMinor}
              currency={payment.quote.net.currency}
            />
          </div>

          {approvalSection(payment)}

          {sameApprover ? (
            <p role="alert" className="text-body-small text-warning dark:text-warning-dark">
              {dict.payments.approval.sameApproverNote}
            </p>
          ) : null}
          {actionError ? (
            <p role="alert" className="text-body-small text-error dark:text-error-dark">
              {actionError}
            </p>
          ) : null}

          {rejectOpen ? (
            <div className="flex flex-col gap-md rounded-lg border border-error p-lg dark:border-error-dark">
              <label
                htmlFor="reject-reason"
                className="text-label-large text-ink-primary dark:text-ink-dark-primary"
              >
                {dict.common.reason}
              </label>
              <textarea
                id="reject-reason"
                value={rejectReason}
                onChange={(e) => {
                  setRejectReason(e.target.value);
                  // Reason is part of the args hash — a changed reason is a
                  // new intent, so the key rotates with it.
                  setRejectKey(newIdempotencyKey());
                }}
                placeholder={dict.common.reasonPlaceholder}
                rows={3}
                className="w-full rounded-md border border-outline bg-surface px-md py-sm text-body-large text-ink-primary outline-none transition-colors duration-normal ease-standard placeholder:text-ink-secondary focus:border-brand-primary dark:border-outline-dark dark:bg-surface-dark dark:text-ink-dark-primary"
              />
              <div className="flex gap-md">
                <button
                  type="button"
                  disabled={busy || rejectReason.trim() === ''}
                  onClick={() => void reject(payment.id)}
                  className={dangerButton}
                >
                  {dict.common.confirm}
                </button>
                <button
                  type="button"
                  onClick={() => setRejectOpen(false)}
                  className={`${buttonClass} border border-outline text-ink-primary hover:bg-surface-muted dark:border-outline-dark dark:text-ink-dark-primary dark:hover:bg-surface-dark-muted`}
                >
                  {dict.common.cancel}
                </button>
              </div>
            </div>
          ) : null}
        </div>
      ) : null}

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
    </Drawer>
  );
}
