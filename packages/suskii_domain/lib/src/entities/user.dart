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

    /// False only for an account that has not answered the first-run
    /// "How would you like to use Suskii Errands?" screen. Accounts that
    /// existed before the screen count as having answered.
    @Default(true) bool roleSelected,

    /// What was chosen on that screen; null for accounts that predate it.
    UserMode? signupRole,

    /// Null when the source does not carry it (a plain `profiles` row);
    /// [effectiveProviderStatus] falls back to the verification standing.
    ProviderStatus? providerStatus,
  }) = _AppUser;

  const AppUser._();

  /// The server's status when known, otherwise the same reading of the
  /// provider verification standing the server makes (less any suspension).
  ProviderStatus get effectiveProviderStatus =>
      providerStatus ??
      switch (providerVerification) {
        VerificationStatus.verified => ProviderStatus.approved,
        VerificationStatus.rejected => ProviderStatus.rejected,
        VerificationStatus.suspended => ProviderStatus.suspended,
        VerificationStatus.inReview => ProviderStatus.pendingApproval,
        VerificationStatus.pending ||
        VerificationStatus.expired => ProviderStatus.pendingVerification,
        VerificationStatus.unverified => ProviderStatus.notRegistered,
      };

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
