import 'package:freezed_annotation/freezed_annotation.dart';

import '../enums.dart';
import '../money.dart';
import 'catalog.dart';
import 'user.dart';

part 'bootstrap.freezed.dart';
part 'bootstrap.g.dart';

/// Compact summary of an in-flight job, shown as a banner across both modes.
@freezed
abstract class ActiveJobBanner with _$ActiveJobBanner {
  const factory ActiveJobBanner({
    required String jobId,
    required JobStatus status,
    required String otherPartyName,
    required String categoryLabelKey,
    Money? agreedPrice,
  }) = _ActiveJobBanner;

  factory ActiveJobBanner.fromJson(Map<String, dynamic> json) =>
      _$ActiveJobBannerFromJson(json);
}

@freezed
abstract class DocumentExpiryWarning with _$DocumentExpiryWarning {
  const factory DocumentExpiryWarning({
    required String documentTypeKey,
    required int daysRemaining,
  }) = _DocumentExpiryWarning;

  factory DocumentExpiryWarning.fromJson(Map<String, dynamic> json) =>
      _$DocumentExpiryWarningFromJson(json);
}

@freezed
abstract class ProviderHomeSummary with _$ProviderHomeSummary {
  const factory ProviderHomeSummary({
    required bool online,
    required VerificationStatus verificationStatus,
    required Money todayEarnings,
    required int completedToday,
    required int nearbyOpenRequests,
    required List<DocumentExpiryWarning> documentWarnings,
  }) = _ProviderHomeSummary;

  factory ProviderHomeSummary.fromJson(Map<String, dynamic> json) =>
      _$ProviderHomeSummaryFromJson(json);
}

/// Everything the app shell needs on cold start.
@freezed
abstract class AppBootstrap with _$AppBootstrap {
  const factory AppBootstrap({
    required CountryPack countryPack,
    required Map<String, bool> featureFlags,
    required String minSupportedAppVersion,
    required int unreadNotifications,
    AppUser? user,
    ActiveJobBanner? activeJobBanner,
  }) = _AppBootstrap;

  factory AppBootstrap.fromJson(Map<String, dynamic> json) =>
      _$AppBootstrapFromJson(json);
}
