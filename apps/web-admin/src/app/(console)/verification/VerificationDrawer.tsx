'use client';

import { useMemo, useState } from 'react';
import { useRouter } from 'next/navigation';
import { useQuery } from '@tanstack/react-query';
import { dict } from '@/lib/i18n';
import { newIdempotencyKey } from '@/lib/idempotency';
import { serverClockOffsetMs } from '@/lib/serverClock';
import {
  isAppError,
  sessionRepository,
  verificationRepository,
} from '@/mocks/repositories';
import type { DocumentViewGrant } from '@/mocks/types';
import { CopyButton } from '@/components/CopyButton';
import { CountdownTimer } from '@/components/CountdownTimer';
import { Drawer } from '@/components/Drawer';
import { ReauthModal } from '@/components/ReauthModal';
import { StateBlock } from '@/components/StateBlock';
import { StatusChip } from '@/components/StatusChip';
import { can, errorText, formatDateTime, isSessionError, useAdminSession } from '../_shared';

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

export function VerificationDrawer({
  itemId,
  onClose,
}: {
  itemId: string | null;
  onClose: () => void;
}) {
  const router = useRouter();
  const sessionQuery = useAdminSession();
  const role = sessionQuery.data?.admin.role;
  const mayViewDocument = role !== undefined && can(role, 'verification.view_document');

  const clockOffsetMs = useMemo(() => serverClockOffsetMs(), []);

  const itemQuery = useQuery({
    queryKey: ['verification', 'item', itemId],
    queryFn: () => verificationRepository.getItem(itemId!),
    enabled: itemId !== null,
  });

  const [grant, setGrant] = useState<DocumentViewGrant | null>(null);
  const [viewBusy, setViewBusy] = useState(false);
  const [viewError, setViewError] = useState<string | null>(null);
  const [reauthOpen, setReauthOpen] = useState(false);
  const [reauthError, setReauthError] = useState<string | null>(null);
  // One key per document-view intent; kept across the reauth retry, reset
  // after success so a later "view again" is a fresh intent.
  const [viewKey, setViewKey] = useState(() => newIdempotencyKey());

  const requestView = async (targetItemId: string) => {
    setViewBusy(true);
    setViewError(null);
    try {
      const g = await verificationRepository.requestDocumentView(targetItemId, viewKey);
      setGrant(g);
      setViewKey(newIdempotencyKey());
    } catch (e) {
      if (isAppError(e, 'ERR_REAUTH_REQUIRED')) {
        // Sensitive action: re-authenticate, then retry with the SAME key.
        setReauthError(null);
        setReauthOpen(true);
      } else if (isSessionError(e)) {
        router.replace('/sign-in');
      } else {
        setViewError(errorText(e));
      }
    } finally {
      setViewBusy(false);
    }
  };

  const confirmReauth = async (_code: string) => {
    // The mock reauth records the purpose in the audit log; the authenticator
    // code itself is not verified at this layer.
    try {
      await sessionRepository.reauth('verification.view_document');
      setReauthOpen(false);
      if (itemId) await requestView(itemId);
    } catch (e) {
      if (isSessionError(e)) {
        router.replace('/sign-in');
      } else {
        setReauthError(errorText(e));
      }
    }
  };

  const item = itemQuery.data;
  const reasonLabel = item?.decisionReasonKey
    ? ((dict.verification.rejectionReasons as Record<string, string>)[
        item.decisionReasonKey
      ] ?? item.decisionReasonKey)
    : null;

  return (
    <Drawer
      open={itemId !== null}
      onClose={onClose}
      title={item?.subjectName ?? ''}
      closeLabel={dict.common.close}
    >
      {itemQuery.isPending ? (
        <StateBlock variant="loading" />
      ) : itemQuery.isError ? (
        <StateBlock
          variant="error"
          errorMessage={errorText(itemQuery.error)}
          retryLabel={dict.common.retry}
          onRetry={() => void itemQuery.refetch()}
        />
      ) : item ? (
        <div className="flex flex-col gap-lg">
          <StatusChip
            label={
              (dict.verification.statuses as Record<string, string>)[item.status] ??
              item.status
            }
            tone={
              item.status === 'approved'
                ? 'success'
                : item.status === 'rejected'
                  ? 'error'
                  : item.status === 'in_review'
                    ? 'warning'
                    : 'neutral'
            }
          />

          <div className="divide-y divide-outline dark:divide-outline-dark">
            <DetailRow
              label={dict.nav.verification}
              value={dict.verification.tabs[item.kind]}
            />
            <DetailRow
              label={dict.verification.columns.subject}
              value={dict.verification.subjectTypes[item.subjectType]}
            />
            <DetailRow
              label={dict.directory.columns.country}
              value={
                (dict.dashboard.countries as Record<string, string>)[item.country] ??
                item.country
              }
            />
            <DetailRow
              label={dict.verification.columns.submitted}
              value={formatDateTime(item.submittedAt)}
            />
            {item.claimedByAdminId ? (
              <DetailRow
                label={dict.verification.columns.claimedBy}
                value={item.claimedByAdminId}
              />
            ) : null}
            {item.reviewedAt ? (
              <DetailRow
                label={dict.verification.columns.reviewed}
                value={formatDateTime(item.reviewedAt)}
              />
            ) : null}
            {reasonLabel ? (
              <DetailRow label={dict.common.reason} value={reasonLabel} />
            ) : null}
          </div>

          <section className="rounded-lg border border-outline bg-surface-raised p-lg dark:border-outline-dark dark:bg-surface-dark-raised">
            <p className="text-body-small text-ink-secondary dark:text-ink-dark-secondary">
              {dict.verification.viewer.shortLivedNotice}
            </p>
            {grant ? (
              <div className="mt-md flex flex-col gap-sm">
                <p className="break-all text-body-small text-ink-primary dark:text-ink-dark-primary">
                  {grant.url}
                </p>
                <div className="flex items-center gap-md">
                  <CopyButton
                    text={grant.url}
                    label={dict.common.copy}
                    copiedLabel={dict.common.copied}
                  />
                  <CountdownTimer
                    deadline={grant.expiresAt.toISOString()}
                    clockOffsetMs={clockOffsetMs}
                    expiredLabel={dict.verification.viewer.tokenExpired}
                    className="text-body-small text-ink-secondary dark:text-ink-dark-secondary"
                  />
                </div>
              </div>
            ) : null}
            {mayViewDocument ? (
              <button
                type="button"
                disabled={viewBusy}
                onClick={() => void requestView(item.id)}
                className="mt-md rounded-md border border-outline px-lg py-sm text-label-large text-ink-primary transition-colors duration-normal ease-standard hover:bg-surface-muted disabled:opacity-50 dark:border-outline-dark dark:text-ink-dark-primary dark:hover:bg-surface-dark-muted"
              >
                {dict.verification.viewer.viewDocumentCta}
              </button>
            ) : null}
            {viewError ? (
              <p role="alert" className="mt-sm text-body-small text-error dark:text-error-dark">
                {viewError}
              </p>
            ) : null}
          </section>
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
