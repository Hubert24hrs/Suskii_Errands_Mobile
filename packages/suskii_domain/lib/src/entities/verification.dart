import 'package:freezed_annotation/freezed_annotation.dart';

import '../enums.dart';

part 'verification.freezed.dart';
part 'verification.g.dart';

/// One step of a KYC flow. [rejectionReasonKey] is a localization key, never
/// free text (criminal-history notes never reach the client per the spec).
@freezed
abstract class KycStep with _$KycStep {
  const factory KycStep({
    required KycStepKind kind,
    required KycStepStatus status,
    required int attemptCount,
    DateTime? submittedAt,
    DateTime? reviewedAt,
    String? rejectionReasonKey,
  }) = _KycStep;

  factory KycStep.fromJson(Map<String, dynamic> json) =>
      _$KycStepFromJson(json);
}

/// A customer facial-verification session (consent → liveness + ID lookup →
/// result). Outcomes are decided server-side; the client only requests them.
@freezed
abstract class VerificationSession with _$VerificationSession {
  const factory VerificationSession({
    required String id,
    required KycStepKind kind,
    required KycStepStatus status,
    required DateTime updatedAt,
    String? rejectionReasonKey,
    DateTime? expiresAt,
  }) = _VerificationSession;

  factory VerificationSession.fromJson(Map<String, dynamic> json) =>
      _$VerificationSessionFromJson(json);
}

/// A provider's full KYC profile: onboarding choices plus every step's state.
/// [overallStatus] is a server-computed rollup of [steps].
@freezed
abstract class ProviderKycProfile with _$ProviderKycProfile {
  const factory ProviderKycProfile({
    required String userId,
    required ProviderKind kind,
    required List<String> serviceCategoryIds,
    required List<String> serviceAreaIds,
    required List<KycStep> steps,
    required KycStepStatus overallStatus,
    VehicleType? vehicleType,
    DateTime? submittedForReviewAt,
  }) = _ProviderKycProfile;

  factory ProviderKycProfile.fromJson(Map<String, dynamic> json) =>
      _$ProviderKycProfileFromJson(json);
}

/// Server-side payout-account name lookup result. [nameMatch] compares the
/// resolved account name against the verified identity — always computed
/// server-side, never derived by the client.
@freezed
abstract class PayoutAccountResult with _$PayoutAccountResult {
  const factory PayoutAccountResult({
    required String bankCode,
    required String maskedAccountNumber,
    required String resolvedName,
    required bool nameMatch,
  }) = _PayoutAccountResult;

  factory PayoutAccountResult.fromJson(Map<String, dynamic> json) =>
      _$PayoutAccountResultFromJson(json);
}

/// ---------------------------------------------------------------------------
/// Step input DTOs. KYC files are upload-only: they arrive as opaque
/// [uploadRef]s from signed-url uploads and are never read back by clients.
/// ---------------------------------------------------------------------------

class PoliceClearanceInput {
  const PoliceClearanceInput({
    required this.certificateNumber,
    required this.issueDate,
    required this.expiryDate,
    required this.uploadRef,
  });

  final String certificateNumber;
  final DateTime issueDate;
  final DateTime expiryDate;
  final String uploadRef;
}

/// Government-ID lookup (`idType` is a key like `nin`, `bvn`, `ghanaCard`)
/// and ID document capture (add [uploadRef]).
class IdDocumentInput {
  const IdDocumentInput({
    required this.idType,
    required this.idNumber,
    this.uploadRef,
  });

  final String idType;
  final String idNumber;
  final String? uploadRef;
}

class AddressInput {
  const AddressInput({
    required this.line1,
    required this.city,
    required this.state,
    this.line2,
    this.landmarkNote,
  });

  final String line1;
  final String? line2;
  final String city;
  final String state;
  final String? landmarkNote;
}

class GuarantorInput {
  const GuarantorInput({
    required this.fullName,
    required this.phoneE164,
    required this.relationship,
  });

  final String fullName;
  final String phoneE164;
  final String relationship;
}

class PayoutAccountInput {
  const PayoutAccountInput({
    required this.bankCode,
    required this.accountNumber,
  });

  final String bankCode;
  final String accountNumber;
}

class VehicleDocumentsInput {
  const VehicleDocumentsInput({
    required this.licenceUploadRef,
    required this.registrationUploadRef,
    this.insuranceUploadRef,
  });

  final String licenceUploadRef;
  final String registrationUploadRef;
  final String? insuranceUploadRef;
}

class CredentialsInput {
  const CredentialsInput({required this.description, required this.uploadRefs});

  final String description;
  final List<String> uploadRefs;
}

class ProviderOnboardingInput {
  const ProviderOnboardingInput({
    required this.kind,
    required this.serviceCategoryIds,
    required this.serviceAreaIds,
    this.vehicleType,
    this.businessName,
  });

  final ProviderKind kind;
  final List<String> serviceCategoryIds;
  final List<String> serviceAreaIds;
  final VehicleType? vehicleType;
  final String? businessName;
}
