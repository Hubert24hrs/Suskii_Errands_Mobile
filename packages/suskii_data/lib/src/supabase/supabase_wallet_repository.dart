import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_domain/suskii_domain.dart';

import 'supabase_gateway.dart';
import 'supabase_mappers.dart';

/// The caller's currency from the bootstrap envelope (get_bootstrap without
/// args resolves the caller's profile country).
Future<String> myCurrencyCode(SupabaseGateway gateway) async {
  final raw = await gateway.rpc('get_bootstrap');
  final payload = raw as Map<String, dynamic>;
  final pack = payload['country_pack'] as Map<String, dynamic>?;
  final currency = pack?['currency'] as Map<String, dynamic>?;
  return currency?['code'] as String? ?? 'NGN';
}

/// The caller's default payout account id (the withdrawal RPCs need one).
/// Throws AppError(ERR_PAYOUT_ACCOUNT_NOT_FOUND) when none exists — the UI
/// routes to payout-account setup.
Future<String> defaultPayoutAccountId(SupabaseGateway gateway) async {
  final rows = await gateway.selectList(
    'payout_accounts',
    'id',
    column: 'is_default',
    value: true,
  );
  if (rows.isEmpty) {
    throw const AppError(ErrorCodes.payoutAccountNotFound);
  }
  return SupabaseGateway.asId(rows.first['id']);
}

/// WalletRepository over Supabase. The available balance is
/// `available_balance`; what is on its way is `my_pending_balance` (funded
/// jobs not yet recognised); history is `my_wallet_transactions`, a
/// client-safe projection of the private ledger plus the withdrawals that
/// have not reached it (CR-20260923-03, contracts 2.0.0). Withdrawals go
/// through `request_withdrawal` (provider-earnings source, default payout
/// account).
class SupabaseWalletRepository implements WalletRepository {
  SupabaseWalletRepository(this._gateway);

  final SupabaseGateway _gateway;

  @override
  Future<WalletSummary> getSummary() async {
    final currency = await myCurrencyCode(_gateway);
    final available = await _gateway.rpc('available_balance', <String, Object?>{
      'p_source': 'provider_earnings',
      'p_currency': currency,
    });
    final pending = await _gateway.rpc('my_pending_balance', <String, Object?>{
      'p_source': 'provider_earnings',
      'p_currency': currency,
    });
    return WalletSummary(
      available: Money(SupabaseGateway.asMinorUnits(available), currency),
      pending: Money(SupabaseGateway.asMinorUnits(pending), currency),
    );
  }

  @override
  Future<List<WalletTransaction>> getTransactions({
    String? cursor,
    int limit = 20,
  }) async {
    // Cursor is the last row's created_at (ISO-8601).
    final rows = await _gateway.rpc('my_wallet_transactions', <String, Object?>{
      'p_source': 'provider_earnings',
      'p_cursor': cursor,
      'p_limit': limit,
    });
    return List<Map<String, dynamic>>.from(rows as List<dynamic>)
        .map(walletTransactionFromFeedRow)
        .toList(growable: false);
  }

  @override
  Future<WalletTransaction> requestWithdrawal(
    Money amount, {
    required String idempotencyKey,
  }) async {
    final accountId = await defaultPayoutAccountId(_gateway);
    await _gateway.rpc('request_withdrawal', <String, Object?>{
      'p_idempotency_key': idempotencyKey,
      'p_source': 'provider_earnings',
      'p_amount_minor': amount.minorUnits,
      'p_payout_account_id': accountId,
    });
    // The RPC returns the new withdrawal's status scalar; re-select the row
    // for the entity (newest first — the one just created).
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
      kind: WalletTransactionKind.payout,
    );
  }
}
