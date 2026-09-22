import 'package:freezed_annotation/freezed_annotation.dart';

import '../enums.dart';
import '../money.dart';

part 'catalog.freezed.dart';
part 'catalog.g.dart';

@freezed
abstract class ServiceCategory with _$ServiceCategory {
  const factory ServiceCategory({
    required String id,

    /// Localization key, not display text.
    required String labelKey,
    required String iconKey,
    required bool allowsCustom,

    /// Offer TTL for this category (spec default: 10 minutes).
    @Default(600) int offerTtlSeconds,

    /// Max counter rounds per negotiation thread (spec default: 5).
    @Default(5) int maxCounterRounds,

    /// Proof-of-execution required before the provider can mark a job of
    /// this category complete (spec: job_lifecycle.proof; backend
    /// `service_categories.proof_requirements`). Keys are [ProofKind] wire
    /// values ('photo', 'receipt', 'signature'), values the required count.
    /// Server-owned; empty map = no proofs required.
    @Default(<String, int>{}) Map<String, int> proofRequirements,
  }) = _ServiceCategory;

  factory ServiceCategory.fromJson(Map<String, dynamic> json) =>
      _$ServiceCategoryFromJson(json);
}

/// Server-computed price band for a category (price intelligence feature):
/// P25/P50/P75 percentiles of completed jobs. Advisory only — the spec
/// forbids AI setting prices. [basis] tells the UI whether the band comes
/// from completed-job history or from rules (label rules bands as a rough
/// guide, ai-design §9).
@freezed
abstract class PriceBand with _$PriceBand {
  const factory PriceBand({
    required Money p25,
    required Money p50,
    required Money p75,
    required int sampleSize,
    required PriceBandConfidence confidence,
    required PriceBandBasis basis,
  }) = _PriceBand;

  factory PriceBand.fromJson(Map<String, dynamic> json) =>
      _$PriceBandFromJson(json);
}

@freezed
abstract class EmergencyNumber with _$EmergencyNumber {
  const factory EmergencyNumber({
    required String labelKey,
    required String number,
  }) = _EmergencyNumber;

  factory EmergencyNumber.fromJson(Map<String, dynamic> json) =>
      _$EmergencyNumberFromJson(json);
}

/// Client-safe subset of a country pack. All country behaviour is data.
@freezed
abstract class CountryPack with _$CountryPack {
  const factory CountryPack({
    required String countryCode,
    required CountryStatus status,
    required String currencyCode,
    required List<String> supportedLanguages,
    required String defaultLanguage,
    required List<String> launchCities,
    required List<EmergencyNumber> emergencyNumbers,
    required int offerTtlSeconds,
    required int maxNegotiationRounds,
    Money? minWithdrawal,
  }) = _CountryPack;

  factory CountryPack.fromJson(Map<String, dynamic> json) =>
      _$CountryPackFromJson(json);
}
