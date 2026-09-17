import 'package:freezed_annotation/freezed_annotation.dart';

import '../enums.dart';
import '../money.dart';

part 'offer.freezed.dart';
part 'offer.g.dart';

@freezed
abstract class Offer with _$Offer {
  const factory Offer({
    required String id,
    required String requestId,
    required String providerId,
    required String providerName,
    required double providerRating,
    required TrustLevel providerTrustLevel,
    required Money amount,
    required OfferStatus status,

    /// Negotiation round (1-based). Server enforces max rounds per category.
    required int round,
    required DateTime createdAt,
    String? message,

    /// Distance in meters at offer time (server-computed).
    int? distanceMeters,

    /// Estimated minutes for the provider to reach pickup (server-computed).
    int? etaMinutes,

    /// Server-computed estimated payout shown to the provider before submitting.
    PriceBreakdown? payoutEstimate,
    DateTime? expiresAt,
  }) = _Offer;

  factory Offer.fromJson(Map<String, dynamic> json) => _$OfferFromJson(json);
}

/// Authoritative money breakdown. ALWAYS server-computed — the UI renders
/// these values and never derives them.
@freezed
abstract class PriceBreakdown with _$PriceBreakdown {
  const factory PriceBreakdown({
    required Money gross,
    required Money platformCommission,
    required Money net,
    required Money providerPayout,

    /// Commission rate snapshot in basis points (1250 = 12.5%).
    required int commissionRateBps,
    Money? estimatedGatewayFee,
    Money? actualGatewayFee,
    Money? tip,
    Money? referralCommissionTotal,
  }) = _PriceBreakdown;

  factory PriceBreakdown.fromJson(Map<String, dynamic> json) =>
      _$PriceBreakdownFromJson(json);
}
