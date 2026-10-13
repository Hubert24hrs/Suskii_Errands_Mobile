import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_domain/suskii_domain.dart';

import 'supabase_gateway.dart';
import 'supabase_mappers.dart';

/// The business console over Supabase. The organization and its people come
/// from `my_organization` / `my_organization_members` (profiles are readable
/// by their owner only, so a plain select would show ids); a business is
/// created by `register_organization`, which seals the registration number;
/// inviting is by phone (`invite_member_by_phone`) and the invitee sees and
/// accepts through `my_organization_invitations` /
/// `accept_organization_invite`; dispatch is `dispatch_job`, and vehicles are
/// registered and handed out through `register_vehicle` / `assign_vehicle`.
class SupabaseOrganizationRepository implements OrganizationRepository {
  SupabaseOrganizationRepository(this._gateway);

  final SupabaseGateway _gateway;

  Future<Map<String, dynamic>?> _myOrgRow() async {
    final rows = List<Map<String, dynamic>>.from(
      await _gateway.rpc('my_organization') as List<dynamic>,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<String> _requireOrgId() async {
    final row = await _myOrgRow();
    if (row == null) throw const AppError(ErrorCodes.permissionDenied);
    return SupabaseGateway.asId(row['id']);
  }

  @override
  Future<Organization?> getMyOrganization() async {
    final row = await _myOrgRow();
    return row == null ? null : organizationFromRow(row);
  }

  @override
  Future<List<OrgMember>> getMembers() async {
    final rows = List<Map<String, dynamic>>.from(
      await _gateway.rpc('my_organization_members') as List<dynamic>,
    );
    return rows.map(orgMemberFromRow).toList(growable: false);
  }

  @override
  Future<Organization> registerOrganization({
    required String legalName,
    required String registrationNumber,
    required String idempotencyKey,
  }) async {
    await _gateway.rpc('register_organization', <String, Object?>{
      'p_idempotency_key': idempotencyKey,
      'p_legal_name': legalName.trim(),
      'p_registration_number': registrationNumber,
    });
    return _requireMyOrganization();
  }

  @override
  Future<List<OrgInvitation>> getMyInvitations() async {
    final rows = List<Map<String, dynamic>>.from(
      await _gateway.rpc('my_organization_invitations') as List<dynamic>,
    );
    return rows.map(orgInvitationFromRow).toList(growable: false);
  }

  @override
  Future<Organization> acceptInvitation(
    String organizationId, {
    required String idempotencyKey,
  }) async {
    await _gateway.rpc('accept_organization_invite', <String, Object?>{
      'p_idempotency_key': idempotencyKey,
      'p_organization_id': organizationId,
    });
    return _requireMyOrganization();
  }

  Future<Organization> _requireMyOrganization() async {
    final org = await getMyOrganization();
    if (org == null) throw const AppError(ErrorCodes.unknown);
    return org;
  }

  @override
  Future<OrgMember> inviteMember({
    required String phoneE164,
    required BusinessRole role,
    required String idempotencyKey,
  }) async {
    final orgId = await _requireOrgId();
    final userId = SupabaseGateway.asId(
      await _gateway.rpc('invite_member_by_phone', <String, Object?>{
        'p_idempotency_key': idempotencyKey,
        'p_organization_id': orgId,
        'p_phone_e164': phoneE164,
        'p_role': role.name,
      }),
    );
    final members = await getMembers();
    return members.firstWhere(
      (m) => m.userId == userId,
      orElse: () => throw const AppError(ErrorCodes.unknown),
    );
  }

  @override
  Future<void> removeMember(
    String userId, {
    required String idempotencyKey,
  }) async {
    final orgId = await _requireOrgId();
    await _gateway.rpc('remove_member', <String, Object?>{
      'p_organization_id': orgId,
      'p_user_id': userId,
    });
  }

  @override
  Future<List<JobRequest>> getAssignableJobs() async {
    final rows = List<dynamic>.from(
      await _gateway.rpc('org_assignable_jobs') as List<dynamic>,
    );
    return rows
        .map((row) => jobRequestFromRow(Map<String, dynamic>.from(row as Map)))
        .toList(growable: false);
  }

  @override
  Future<JobRequest> assignJob({
    required String jobId,
    required String workerId,
    required String idempotencyKey,
  }) async {
    // Read before dispatching: a dispatcher who is not the accepting account
    // cannot read the request afterwards, and the screen wants the job back.
    final before = (await getAssignableJobs())
        .where((j) => j.id == jobId)
        .firstOrNull;
    final status = await _gateway.rpc('dispatch_job', <String, Object?>{
      'p_idempotency_key': idempotencyKey,
      'p_request_id': jobId,
      'p_worker_id': workerId,
    });
    if (before == null) throw const AppError(ErrorCodes.invalidState);
    return before.copyWith(status: jobStatusFromWire(status));
  }

  @override
  Future<List<Vehicle>> getVehicles() async {
    final orgId = await _requireOrgId();
    final rows = await _gateway.selectList(
      'vehicles',
      'id, organization_id, type, plate_masked, assigned_worker_id, '
          'documents_expire_on',
      column: 'organization_id',
      value: orgId,
      orderBy: 'created_at',
    );
    return rows.map(vehicleFromRow).toList(growable: false);
  }

  /// Registers a new vehicle. An existing one is not edited here: its plate is
  /// sealed and its documents are reviewed, so a change is a new registration.
  @override
  Future<Vehicle> upsertVehicle(
    Vehicle vehicle, {
    required String idempotencyKey,
  }) async {
    final orgId = await _requireOrgId();
    final existing = await getVehicles();
    if (existing.any((v) => v.id == vehicle.id)) {
      throw const AppError(ErrorCodes.featureUnavailable);
    }
    final id = SupabaseGateway.asId(
      await _gateway.rpc('register_vehicle', <String, Object?>{
        'p_idempotency_key': idempotencyKey,
        'p_type': vehicleTypeToWire(vehicle.type),
        'p_plate': vehicle.plate,
        'p_organization_id': orgId,
        'p_assigned_worker_id': vehicle.assignedWorkerId,
        'p_documents_expire_on': vehicle.documentExpiry == null
            ? null
            : dateToWire(vehicle.documentExpiry!),
      }),
    );
    return _vehicle(id);
  }

  @override
  Future<Vehicle> assignVehicle(
    String vehicleId,
    String? workerId, {
    required String idempotencyKey,
  }) async {
    await _gateway.rpc('assign_vehicle', <String, Object?>{
      'p_idempotency_key': idempotencyKey,
      'p_vehicle_id': vehicleId,
      'p_worker_id': workerId,
    });
    return _vehicle(vehicleId);
  }

  Future<Vehicle> _vehicle(String id) async {
    final row = await _gateway.selectSingle(
      'vehicles',
      'id, organization_id, type, plate_masked, assigned_worker_id, '
          'documents_expire_on',
      column: 'id',
      value: id,
    );
    if (row == null) throw const AppError(ErrorCodes.unknown);
    return vehicleFromRow(row);
  }
}

/// A `my_organization` row.
Organization organizationFromRow(Map<String, dynamic> row) => Organization(
  id: SupabaseGateway.asId(row['id']),
  name: row['name'] as String? ?? '',
  ownerId: SupabaseGateway.asId(row['owner_id']),
  verificationStatus: verificationFromWire(row['verification_status']),
  payoutAccountSet: row['payout_account_set'] as bool? ?? false,
  memberCount: (row['member_count'] as num?)?.toInt() ?? 0,
  activeVehicleCount: (row['active_vehicle_count'] as num?)?.toInt() ?? 0,
);

/// A `my_organization_invitations` row.
OrgInvitation orgInvitationFromRow(Map<String, dynamic> row) => OrgInvitation(
  organizationId: SupabaseGateway.asId(row['organization_id']),
  organizationName: row['name'] as String? ?? '',
  role: BusinessRole.values.byName(row['role'] as String),
  invitedAt: SupabaseGateway.asTimestamp(row['invited_at']),
);

/// A `my_organization_members` row. Earnings arrive for the owner only.
OrgMember orgMemberFromRow(Map<String, dynamic> row) => OrgMember(
  userId: SupabaseGateway.asId(row['user_id']),
  displayName: row['display_name'] as String? ?? '',
  role: BusinessRole.values.byName(row['role'] as String),
  verificationStatus: verificationFromWire(row['verification_status']),
  jobsCompleted: (row['jobs_completed'] as num?)?.toInt() ?? 0,
  earningsToDate: row['earnings_minor'] == null
      ? null
      : Money(
          SupabaseGateway.asMinorUnits(row['earnings_minor']),
          row['currency'] as String? ?? 'NGN',
        ),
);

/// A `vehicles` row; the plate is the masked display column.
Vehicle vehicleFromRow(Map<String, dynamic> row) => Vehicle(
  id: SupabaseGateway.asId(row['id']),
  organizationId: row['organization_id'] == null
      ? ''
      : SupabaseGateway.asId(row['organization_id']),
  type: vehicleTypeFromWire(row['type']),
  plate: row['plate_masked'] as String? ?? '',
  assignedWorkerId: row['assigned_worker_id'] == null
      ? null
      : SupabaseGateway.asId(row['assigned_worker_id']),
  documentExpiry: row['documents_expire_on'] == null
      ? null
      : DateTime.parse(row['documents_expire_on'] as String),
);
