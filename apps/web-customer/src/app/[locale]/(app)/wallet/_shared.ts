// Shared helpers for the wallet / referrals / promos routes. Pure functions
// only — safe to import from server or client components.

import type { Dictionary } from '@/lib/i18n/en';
import { isAppError } from '@/mocks/repositories';
import type {
  WalletTransaction,
  WalletTransactionKind,
  WalletTransactionStatus,
} from '@/mocks/types';

type ChipTone = 'neutral' | 'info' | 'success' | 'warning' | 'error';

/** Maps any error to localized copy; unknown codes fall back to ERR_INTERNAL. */
export function errorText(dict: Dictionary, error: unknown): string {
  if (isAppError(error)) {
    const table = dict.errors as Record<string, string>;
    return table[error.code] ?? dict.errors.ERR_INTERNAL;
  }
  return dict.errors.ERR_INTERNAL;
}

/**
 * Localized transaction-kind label. The dict table does not yet carry every
 * wire kind (credit, debit, hold, release, payout, item_float) — those fall
 * back to the raw key (reported as missing keys).
 */
export function walletKindLabel(dict: Dictionary, kind: WalletTransactionKind): string {
  const table = dict.wallet.transactionKinds as Record<string, string>;
  return table[kind] ?? kind;
}

/**
 * Localized transaction-status label from dict.wallet.transactionStatuses.
 */
export function walletTxnStatusLabel(
  dict: Dictionary,
  status: WalletTransactionStatus,
): string {
  const table = (dict.wallet as { transactionStatuses?: Record<string, string> })
    .transactionStatuses;
  return table?.[status] ?? status;
}

export function walletTxnStatusTone(status: WalletTransactionStatus): ChipTone {
  switch (status) {
    case 'completed':
      return 'success';
    case 'pending':
    case 'awaiting_approval':
      return 'warning';
    case 'failed':
    case 'reversed':
      return 'error';
    default:
      return 'neutral';
  }
}

/** Kinds that move money INTO the wallet — rendered with a positive sign. */
const CREDIT_KINDS: ReadonlySet<WalletTransactionKind> = new Set([
  'credit',
  'refund',
  'release',
  'referral',
  'tip',
]);

/** Display sign only — the amount itself always comes from the server. */
export function signedAmountMinor(txn: WalletTransaction): number {
  return CREDIT_KINDS.has(txn.kind) ? txn.amount.amountMinor : -txn.amount.amountMinor;
}

/** en-NG formatting for both locales (pcm has no Intl locale data). */
export function formatDate(date: Date): string {
  return new Intl.DateTimeFormat('en-NG', { dateStyle: 'medium' }).format(date);
}

export function formatDateTime(date: Date): string {
  return new Intl.DateTimeFormat('en-NG', {
    dateStyle: 'medium',
    timeStyle: 'short',
  }).format(date);
}
