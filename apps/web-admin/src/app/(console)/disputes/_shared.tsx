'use client';

// Shared helpers for the disputes module (list + detail).

import { dict } from '@/lib/i18n';
import { serverNow } from '@/lib/serverClock';
import type { DisputeCaseStatus, DisputeResolutionAction } from '@/mocks/types';
import { StatusChip } from '@/components/StatusChip';

export function disputeStatusChip(status: DisputeCaseStatus) {
  const label = (dict.disputes.statuses as Record<string, string>)[status] ?? status;
  const tone =
    status === 'resolved'
      ? 'success'
      : status === 'rejected'
        ? 'error'
        : status === 'in_review'
          ? 'info'
          : 'warning';
  return <StatusChip label={label} tone={tone} />;
}

/** Reason keys are literal fixture values (e.g. 'dispute.item_damaged'). */
export function disputeReasonLabel(reasonKey: string): string {
  return (dict.disputes.reasons as Record<string, string>)[reasonKey] ?? reasonKey;
}

export function resolutionActionLabel(action: DisputeResolutionAction): string {
  const map: Record<DisputeResolutionAction, string> = {
    refund_full: dict.disputes.detail.actions.refundFull,
    refund_partial: dict.disputes.detail.actions.refundPartial,
    release_to_provider: dict.disputes.detail.actions.releaseToProvider,
    reject: dict.disputes.detail.actions.rejectDispute,
  };
  return map[action];
}

/** Labels for the server-computed quote lines. */
export function quoteLineLabel(key: 'refundToCustomer' | 'releaseToProvider' | 'platformRetained') {
  return dict.disputes.detail.quote[key];
}

/** Whole days since opening, against the simulated server clock. */
export function ageDays(openedAt: Date): string {
  const days = Math.max(
    0,
    Math.floor((serverNow().getTime() - openedAt.getTime()) / 86_400_000),
  );
  return `${days}d`;
}
