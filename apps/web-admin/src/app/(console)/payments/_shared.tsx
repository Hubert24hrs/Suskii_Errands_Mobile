'use client';

// Shared helpers for the payments module (list + approval drawer).

import { dict } from '@/lib/i18n';
import { serverNow } from '@/lib/serverClock';
import type { PaymentAdminKind, PaymentAdminStatus } from '@/mocks/types';
import { StatusChip } from '@/components/StatusChip';

export type PaymentTab = keyof typeof dict.payments.tabs;

export const TAB_KIND: Record<PaymentTab, PaymentAdminKind> = {
  holds: 'hold',
  settlements: 'settlement',
  payouts: 'payout',
  withdrawals: 'withdrawal',
};

export function paymentStatusChip(status: PaymentAdminStatus) {
  const label = (dict.payments.statuses as Record<string, string>)[status] ?? status;
  const tone =
    status === 'completed'
      ? 'success'
      : status === 'failed'
        ? 'error'
        : status === 'pending'
          ? 'warning'
          : status === 'held' || status === 'processing'
            ? 'info'
            : 'neutral';
  return <StatusChip label={label} tone={tone} />;
}

export function kindLabel(kind: PaymentAdminKind): string {
  const tab = (Object.keys(TAB_KIND) as PaymentTab[]).find((t) => TAB_KIND[t] === kind);
  return tab ? dict.payments.tabs[tab] : kind;
}

/** Whole days since creation, against the simulated server clock. */
export function ageDays(createdAt: Date): string {
  const days = Math.max(
    0,
    Math.floor((serverNow().getTime() - createdAt.getTime()) / 86_400_000),
  );
  return `${days}d`;
}
