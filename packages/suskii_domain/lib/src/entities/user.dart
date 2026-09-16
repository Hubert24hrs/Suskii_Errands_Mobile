import 'package:freezed_annotation/freezed_annotation.dart';

import '../enums.dart';

part 'user.freezed.dart';
part 'user.g.dart';

@freezed
abstract class AppUser with _$AppUser {
  const factory AppUser({
    required String id,
    required String displayName,
    required String countryCode,
    required String preferredLanguage,
    required UserMode activeMode,
    required VerificationStatus customerVerification,
    required VerificationStatus providerVerification,
    required TrustLevel trustLevel,
    required DateTime createdAt,
    String? phoneE164,
    String? email,
    String? photoUrl,
    String? referralCode,
  }) = _AppUser;

  factory AppUser.fromJson(Map<String, dynamic> json) =>
      _$AppUserFromJson(json);
}

@freezed
abstract class ProviderProfile with _$ProviderProfile {
  const factory ProviderProfile({
    required String userId,
    required ProviderKind kind,
    required List<String> serviceCategoryIds,
    required List<String> serviceAreaIds,
    required double rating,
    required int completedJobs,
    required double cancellationRate,
    required int avgResponseTimeSeconds,
    required bool online,
    required VerificationStatus verificationStatus,
    String? displayName,
    String? photoUrl,
    String? businessName,
    String? organizationId,
    VehicleType? vehicleType,
  }) = _ProviderProfile;

  factory ProviderProfile.fromJson(Map<String, dynamic> json) =>
      _$ProviderProfileFromJson(json);
}
