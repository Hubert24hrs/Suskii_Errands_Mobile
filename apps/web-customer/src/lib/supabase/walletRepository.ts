// WalletRepository over Supabase: the balance comes from the private
// double-entry ledger via `available_balance`; withdrawals go through
// `request_withdrawal` (provider-earnings source, default payout account).
// Mirrors
// packages/suskii_data/lib/src/supabase/supabase_wallet_repository.dart.

import { AppError, ErrorCodes } from '@/mocks/errors';
import type { Money, WalletSummary, WalletTransaction } from '@/mocks/types';

import { SupabaseGateway, type Row } from './gateway';
import { withdrawalTransactionFromRow } from './mappers';

const withdrawalColumns = 'id, amount_minor, currency, status, created_at';

/** The caller's currency from the bootstrap envelope (get_bootstrap without
 * args resolves the caller's profile country). */
export async function myCurrencyCode(gateway: SupabaseGateway): Promise<string> {
  const payload = (await gateway.rpc('get_bootstrap')) as Row;
  const pack = payload['country_pack'] as Row | null;
  const currency = pack?.['currency'] as Row | null;
  return (currency?.['code'] as string | null) ?? 'NGN';
}

/** The caller's default payout account id (the withdrawal RPCs need one).
 * Throws AppError(ERR_PAYOUT_ACCOUNT_NOT_FOUND) when none exists — the UI
 * routes to payout-account setup. */
export async function defaultPayoutAccountId(
  gateway: SupabaseGateway,
): Promise<string> {
  const rows = await gateway.selectList('payout_accounts', 'id', {
    column: 'is_default',
    value: true,
  });
  if (rows.length === 0) throw new AppError(ErrorCodes.payoutAccountNotFound);
  return SupabaseGateway.asId(rows[0]['id']);
}

export class SupabaseWalletRepository {
  constructor(private readonly gateway: SupabaseGateway) {}

  async getSummary(): Promise<WalletSummary> {
    const currency = await myCurrencyCode(this.gateway);
    const available = await this.gateway.rpc('available_balance', {
      p_source: 'provider_earnings',
      p_currency: currency,
    });
    // The contract exposes no "pending" read for user accounts (my_balances
    // returns posted balances only) — pending reports zero until
    // CR-20260923-03 lands a ledger read that can answer it.
    return {
      available: {
        amountMinor: SupabaseGateway.asMinorUnits(available),
        currency,
      },
      pending: { amountMinor: 0, currency },
    };
  }

  async getTransactions(options?: {
    cursor?: string;
    limit?: number;
  }): Promise<WalletTransaction[]> {
    // PROVISIONAL (CR-20260923-03): the private ledger is not client-readable
    // by design, so history is withdrawals-only until the contract grows a
    // transaction feed. Cursor is the last row's created_at (ISO-8601).
    const rows = await this.gateway.selectList('withdrawals', withdrawalColumns, {
      ltColumn: options?.cursor != null ? 'created_at' : undefined,
      ltValue: options?.cursor,
      orderBy: 'created_at',
      ascending: false,
      limit: options?.limit ?? 20,
    });
    return rows.map((row) => withdrawalTransactionFromRow(row, 'payout'));
  }

  async requestWithdrawal(
    amount: Money,
    idempotencyKey: string,
  ): Promise<WalletTransaction> {
    const accountId = await defaultPayoutAccountId(this.gateway);
    await this.gateway.rpc('request_withdrawal', {
      p_idempotency_key: idempotencyKey,
      p_source: 'provider_earnings',
      p_amount_minor: amount.amountMinor,
      p_payout_account_id: accountId,
    });
    // The RPC returns the new withdrawal's status scalar; re-select the row
    // for the entity (newest first — the one just created).
    const rows = await this.gateway.selectList('withdrawals', withdrawalColumns, {
      orderBy: 'created_at',
      ascending: false,
      limit: 1,
    });
    if (rows.length === 0) throw new AppError(ErrorCodes.unknown);
    return withdrawalTransactionFromRow(rows[0], 'payout');
  }
}
