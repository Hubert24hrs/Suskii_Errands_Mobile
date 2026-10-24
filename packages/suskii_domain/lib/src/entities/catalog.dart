import 'package:freezed_annotation/freezed_annotation.dart';

import '../enums.dart';
import '../geo_point.dart';
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
/// One place a provider can serve (a `cities` row): a stable code for the
/// server and a name for people.
@freezed
abstract class ServiceArea with _$ServiceArea {
  const factory ServiceArea({required String code, required String name}) =
      _ServiceArea;

  factory ServiceArea.fromJson(Map<String, dynamic> json) =>
      _$ServiceAreaFromJson(json);
}

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

    /// Where a provider can work: in Nigeria the 36 states and the FCT.
    /// [ServiceArea.code] is what `update_provider_service_areas` takes.
    @Default(<ServiceArea>[]) List<ServiceArea> serviceAreas,
  }) = _CountryPack;

  factory CountryPack.fromJson(Map<String, dynamic> json) =>
      _$CountryPackFromJson(json);
}

/// One blurred area on the "providers near you" map: the centre of a grid
/// cell (about 1 km) and how many providers are in it. Never a provider's
/// position; a cell with too few providers is not shown at all.
@freezed
abstract class NearbyArea with _$NearbyArea {
  const factory NearbyArea({required GeoPoint center, required int providers}) =
      _NearbyArea;

  factory NearbyArea.fromJson(Map<String, dynamic> json) =>
      _$NearbyAreaFromJson(json);
}

/// How many providers are online within [radiusMeters] of a point, and the
/// areas dense enough to show (`nearby_providers`).
@freezed
abstract class NearbyProviders with _$NearbyProviders {
  const factory NearbyProviders({
    required int total,
    required int radiusMeters,
    required List<NearbyArea> areas,
  }) = _NearbyProviders;

  factory NearbyProviders.fromJson(Map<String, dynamic> json) =>
      _$NearbyProvidersFromJson(json);
}
