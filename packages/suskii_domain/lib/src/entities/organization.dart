import 'package:freezed_annotation/freezed_annotation.dart';

import '../enums.dart';
import '../money.dart';

part 'organization.freezed.dart';
part 'organization.g.dart';

/// A business provider (spec: business_accounts_and_fleets). Business
/// verification + owner KYC gate everything; payouts go to the org's verified
/// payout account.
@freezed
abstract class Organization with _$Organization {
  const factory Organization({
    required String id,
    required String name,
    required String ownerId,
    required VerificationStatus verificationStatus,
    required bool payoutAccountSet,
    required int memberCount,
    required int activeVehicleCount,
  }) = _Organization;

  factory Organization.fromJson(Map<String, dynamic> json) =>
      _$OrganizationFromJson(json);
}

/// A member of an organization. Per-worker earnings are visible to the Owner
/// only (enforced server-side; the mock redacts them for other roles).
@freezed
abstract class OrgMember with _$OrgMember {
  const factory OrgMember({
    required String userId,
    required String displayName,
    required BusinessRole role,
    required VerificationStatus verificationStatus,
    required int jobsCompleted,

    /// Null when the viewer is not the owner.
    Money? earningsToDate,
  }) = _OrgMember;

  factory OrgMember.fromJson(Map<String, dynamic> json) =>
      _$OrgMemberFromJson(json);
}

/// Vehicle-registry entry (spec: type, plate, documents, assigned worker,
/// document expiry).
@freezed
abstract class Vehicle with _$Vehicle {
  const factory Vehicle({
    required String id,
    required String organizationId,
    required VehicleType type,
    required String plate,
    String? assignedWorkerId,
    DateTime? documentExpiry,
  }) = _Vehicle;

  factory Vehicle.fromJson(Map<String, dynamic> json) =>
      _$VehicleFromJson(json);
}
