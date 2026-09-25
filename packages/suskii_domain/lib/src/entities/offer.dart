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

/// One row of the server's `rank_offers`: a live offer plus its ranking
/// metadata. Rows arrive in server score order and the board displays that
/// order as-is — it is NOT a price sort (half the weight is price relative
/// to the other offers, the rest is reputation), so the client never
/// re-sorts and never presents it as "sorted by price".
@freezed
abstract class RankedOffer with _$RankedOffer {
  const factory RankedOffer({
    required String offerId,
    required String providerId,
    required String displayName,
    required Money amount,

    /// Server score (higher ranks first). Display-only: the wire sends
    /// numeric-as-string and the mapper parses it once via asDecimal.
    required double score,

    /// Provider rating in stars, from the wire's milli-rating. Shown next to
    /// [ratingCount] — a 5.0 from one job is not a 5.0 from two hundred.
    required double ratingAvg,
    required int ratingCount,

    /// Fraction of the provider's started jobs they completed (0–1), from
    /// the wire's basis points.
    required double completionRate,
    required RankedOfferFactors factors,
  }) = _RankedOffer;

  factory RankedOffer.fromJson(Map<String, dynamic> json) =>
      _$RankedOfferFromJson(json);
}

/// Why a ranked offer sits where it does — the card uses these to explain
/// the ranking instead of leaving it opaque.
@freezed
abstract class RankedOfferFactors with _$RankedOfferFactors {
  const factory RankedOfferFactors({
    /// Cheapest of the offers compared (price is half the score weight).
    required bool cheapest,

    /// Unrated/new provider — scored a neutral 0.6 by the server rather
    /// than zero, so newcomers are not starved.
    required bool newProvider,

    /// How many live offers the scores were computed against.
    required int offersCompared,
  }) = _RankedOfferFactors;

  factory RankedOfferFactors.fromJson(Map<String, dynamic> json) =>
      _$RankedOfferFactorsFromJson(json);
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
