import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_domain/suskii_domain.dart';

import 'supabase_gateway.dart';
import 'supabase_mappers.dart';
import 'supabase_wallet_repository.dart';

/// ReferralRepository over Supabase: the code, per-status commission totals
/// and the referral list come from the `my_referral_*` RPCs; withdrawals go
/// through `request_withdrawal` with the referral-earnings source.
class SupabaseReferralRepository implements ReferralRepository {
  SupabaseReferralRepository(this._gateway);

  final SupabaseGateway _gateway;

  @override
  Future<ReferralSummary> getSummary() async {
    final currency = await myCurrencyCode(_gateway);
    final code = await _gateway.rpc('my_referral_code');
    final summaryRows = List<Map<String, dynamic>>.from(
      await _gateway.rpc('my_referral_summary') as List<dynamic>,
    );
    final referrals = List<Map<String, dynamic>>.from(
      await _gateway.rpc('my_referrals') as List<dynamic>,
    );
    final totals = referralTotalsFromRows(summaryRows, currency);
    final now = DateTime.now().toUtc();
    return ReferralSummary(
      code: code as String,
      shareLink: 'https://suskii.app/r/$code',
      invitedCount: referrals.length,
      activeReferrals: referrals.where((row) {
        final expiresAt = row['expires_at'] as String?;
        return expiresAt == null ||
            SupabaseGateway.asTimestamp(expiresAt).isAfter(now);
      }).length,
      earnedTotal: totals.earnedTotal,
      holding: totals.holding,
      available: totals.available,
    );
  }

  @override
  Future<WalletTransaction> requestWithdrawal(
    Money amount, {
    required String idempotencyKey,
  }) async {
    final accountId = await defaultPayoutAccountId(_gateway);
    await _gateway.rpc('request_withdrawal', <String, Object?>{
      'p_idempotency_key': idempotencyKey,
      'p_source': 'referral_earnings',
      'p_amount_minor': amount.minorUnits,
      'p_payout_account_id': accountId,
    });
    final rows = await _gateway.selectList(
      'withdrawals',
      'id, amount_minor, currency, status, created_at',
      orderBy: 'created_at',
      ascending: false,
      limit: 1,
    );
    if (rows.isEmpty) throw const AppError(ErrorCodes.unknown);
    return withdrawalTransactionFromRow(
      rows.first,
      kind: WalletTransactionKind.referral,
    );
  }
}
