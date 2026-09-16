import 'package:freezed_annotation/freezed_annotation.dart';

import '../enums.dart';
import '../money.dart';

part 'wallet.freezed.dart';
part 'wallet.g.dart';

/// Balances are derived server-side from the double-entry ledger.
@freezed
abstract class WalletSummary with _$WalletSummary {
  const factory WalletSummary({
    required Money available,
    required Money pending,
    Money? lifetimeEarned,
  }) = _WalletSummary;

  factory WalletSummary.fromJson(Map<String, dynamic> json) =>
      _$WalletSummaryFromJson(json);
}

@freezed
abstract class WalletTransaction with _$WalletTransaction {
  const factory WalletTransaction({
    required String id,
    required WalletTransactionKind kind,
    required WalletTransactionStatus status,
    required Money amount,
    required DateTime createdAt,
    String? referenceId,

    /// Localization key for the human-readable description.
    String? descriptionKey,
  }) = _WalletTransaction;

  factory WalletTransaction.fromJson(Map<String, dynamic> json) =>
      _$WalletTransactionFromJson(json);
}
