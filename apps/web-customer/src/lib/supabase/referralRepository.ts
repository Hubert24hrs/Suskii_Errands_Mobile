// ReferralRepository over Supabase: the code, per-status commission totals
// and the referral list come from the `my_referral_*` RPCs; withdrawals go
// through `request_withdrawal` with the referral-earnings source. Mirrors
// packages/suskii_data/lib/src/supabase/supabase_referral_repository.dart.

import { AppError, ErrorCodes } from '@/mocks/errors';
import type { Money, ReferralSummary, WalletTransaction } from '@/mocks/types';

import { SupabaseGateway, type Row } from './gateway';
import { referralTotalsFromRows, withdrawalTransactionFromRow } from './mappers';
import { defaultPayoutAccountId, myCurrencyCode } from './walletRepository';

export class SupabaseReferralRepository {
  constructor(private readonly gateway: SupabaseGateway) {}

  async getSummary(): Promise<ReferralSummary> {
    const currency = await myCurrencyCode(this.gateway);
    const code = (await this.gateway.rpc('my_referral_code')) as string;
    const summaryRows = (await this.gateway.rpc('my_referral_summary')) as Row[];
    const referrals = (await this.gateway.rpc('my_referrals')) as Row[];
    const totals = referralTotalsFromRows(summaryRows, currency);
    const now = Date.now();
    return {
      code,
      shareLink: `https://suskii.app/r/${code}`,
      invitedCount: referrals.length,
      activeReferrals: referrals.filter((row) => {
        const expiresAt = row['expires_at'] as string | null;
        return (
          expiresAt === null ||
          SupabaseGateway.asTimestamp(expiresAt).getTime() > now
        );
      }).length,
      earnedTotal: totals.earnedTotal,
      holding: totals.holding,
      available: totals.available,
    };
  }

  async requestWithdrawal(
    amount: Money,
    idempotencyKey: string,
  ): Promise<WalletTransaction> {
    const accountId = await defaultPayoutAccountId(this.gateway);
    await this.gateway.rpc('request_withdrawal', {
      p_idempotency_key: idempotencyKey,
      p_source: 'referral_earnings',
      p_amount_minor: amount.amountMinor,
      p_payout_account_id: accountId,
    });
    const rows = await this.gateway.selectList(
      'withdrawals',
      'id, amount_minor, currency, status, created_at',
      { orderBy: 'created_at', ascending: false, limit: 1 },
    );
    if (rows.length === 0) throw new AppError(ErrorCodes.unknown);
    return withdrawalTransactionFromRow(rows[0], 'referral');
  }
}
