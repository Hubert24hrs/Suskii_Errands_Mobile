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
  }) = _ServiceCategory;

  factory ServiceCategory.fromJson(Map<String, dynamic> json) =>
      _$ServiceCategoryFromJson(json);
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
