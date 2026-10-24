// The business console over Supabase, as the mobile app runs it
// (packages/suskii_data/lib/src/supabase/supabase_organization_repository.dart):
// the organization and its people from `my_organization` /
// `my_organization_members`; `register_organization` seals the registration
// number; inviting is by phone (`invite_member_by_phone`) and the invitee
// accepts through `my_organization_invitations` / `accept_organization_invite`;
// dispatch is `dispatch_job`; vehicles are `register_vehicle` /
// `assign_vehicle`, the plate shown masked.

import { AppError, ErrorCodes } from '@/mocks/errors';
import type {
  BusinessRole,
  JobRequest,
  OrgInvitation,
  OrgMember,
  Organization,
  Vehicle,
  VehicleType,
} from '@/mocks/types';

import { SupabaseGateway, type Row } from './gateway';
import { jobRequestFromRow, jobStatusFromWire, verificationFromWire } from './mappers';

const vehicleColumns = 'id, organization_id, type, plate_masked, assigned_worker_id, documents_expire_on';

function role(value: unknown): BusinessRole {
  return value === 'owner' || value === 'dispatcher' ? value : 'worker';
}

export function organizationFromRow(row: Row): Organization {
  return {
    id: SupabaseGateway.asId(row['id']),
    name: (row['name'] as string | null) ?? '',
    ownerId: SupabaseGateway.asId(row['owner_id']),
    verificationStatus: verificationFromWire(row['verification_status']),
    payoutAccountSet: row['payout_account_set'] === true,
    memberCount: Number(row['member_count'] ?? 0),
    activeVehicleCount: Number(row['active_vehicle_count'] ?? 0),
  };
}

export function orgInvitationFromRow(row: Row): OrgInvitation {
  return {
    organizationId: SupabaseGateway.asId(row['organization_id']),
    organizationName: (row['name'] as string | null) ?? '',
    role: role(row['role']),
    invitedAt: SupabaseGateway.asTimestamp(row['invited_at']),
  };
}

/** Earnings arrive for the owner only. */
export function orgMemberFromRow(row: Row): OrgMember {
  return {
    userId: SupabaseGateway.asId(row['user_id']),
    displayName: (row['display_name'] as string | null) ?? '',
    role: role(row['role']),
    verificationStatus: verificationFromWire(row['verification_status']),
    jobsCompleted: Number(row['jobs_completed'] ?? 0),
    earningsToDate:
      row['earnings_minor'] == null
        ? undefined
        : {
            amountMinor: SupabaseGateway.asMinorUnits(row['earnings_minor']),
            currency: (row['currency'] as string | null) ?? 'NGN',
          },
  };
}

export function vehicleFromRow(row: Row): Vehicle {
  return {
    id: SupabaseGateway.asId(row['id']),
    organizationId: row['organization_id'] == null ? '' : SupabaseGateway.asId(row['organization_id']),
    type: row['type'] as VehicleType,
    plate: (row['plate_masked'] as string | null) ?? '',
    assignedWorkerId: row['assigned_worker_id'] == null ? undefined : SupabaseGateway.asId(row['assigned_worker_id']),
    documentExpiry: row['documents_expire_on'] == null ? undefined : new Date(row['documents_expire_on'] as string),
  };
}

export class SupabaseOrganizationRepository {
  constructor(private readonly gateway: SupabaseGateway) {}

  private async myOrgRow(): Promise<Row | undefined> {
    const rows = (await this.gateway.rpc('my_organization')) as Row[];
    return rows[0];
  }

  private async requireOrgId(): Promise<string> {
    const row = await this.myOrgRow();
    if (!row) throw new AppError(ErrorCodes.permissionDenied);
    return SupabaseGateway.asId(row['id']);
  }

  private async requireMyOrganization(): Promise<Organization> {
    const org = await this.getMyOrganization();
    if (!org) throw new AppError(ErrorCodes.unknown);
    return org;
  }

  async getMyOrganization(): Promise<Organization | undefined> {
    const row = await this.myOrgRow();
    return row ? organizationFromRow(row) : undefined;
  }

  async getMembers(): Promise<OrgMember[]> {
    const rows = (await this.gateway.rpc('my_organization_members')) as Row[];
    return rows.map(orgMemberFromRow);
  }

  async registerOrganization(options: {
    legalName: string;
    registrationNumber: string;
    idempotencyKey: string;
  }): Promise<Organization> {
    await this.gateway.rpc('register_organization', {
      p_idempotency_key: options.idempotencyKey,
      p_legal_name: options.legalName.trim(),
      p_registration_number: options.registrationNumber,
    });
    return this.requireMyOrganization();
  }

  async getMyInvitations(): Promise<OrgInvitation[]> {
    const rows = (await this.gateway.rpc('my_organization_invitations')) as Row[];
    return rows.map(orgInvitationFromRow);
  }

  async acceptInvitation(organizationId: string, idempotencyKey: string): Promise<Organization> {
    await this.gateway.rpc('accept_organization_invite', {
      p_idempotency_key: idempotencyKey,
      p_organization_id: organizationId,
    });
    return this.requireMyOrganization();
  }

  async inviteMember(options: { phoneE164: string; role: BusinessRole; idempotencyKey: string }): Promise<OrgMember> {
    const orgId = await this.requireOrgId();
    const userId = SupabaseGateway.asId(
      await this.gateway.rpc('invite_member_by_phone', {
        p_idempotency_key: options.idempotencyKey,
        p_organization_id: orgId,
        p_phone_e164: options.phoneE164,
        p_role: options.role,
      }),
    );
    const member = (await this.getMembers()).find((m) => m.userId === userId);
    if (!member) throw new AppError(ErrorCodes.unknown);
    return member;
  }

  async removeMember(userId: string, _idempotencyKey: string): Promise<void> {
    const orgId = await this.requireOrgId();
    await this.gateway.rpc('remove_member', { p_organization_id: orgId, p_user_id: userId });
  }

  async getAssignableJobs(): Promise<JobRequest[]> {
    const rows = (await this.gateway.rpc('org_assignable_jobs')) as Row[];
    return rows.map((row) => jobRequestFromRow(row));
  }

  /** Read before dispatching: a dispatcher may not read the request afterwards. */
  async assignJob(options: { jobId: string; workerId: string; idempotencyKey: string }): Promise<JobRequest> {
    const before = (await this.getAssignableJobs()).find((job) => job.id === options.jobId);
    const status = await this.gateway.rpc('dispatch_job', {
      p_idempotency_key: options.idempotencyKey,
      p_request_id: options.jobId,
      p_worker_id: options.workerId,
    });
    if (!before) throw new AppError(ErrorCodes.invalidState);
    return { ...before, status: jobStatusFromWire(status) };
  }

  async getVehicles(): Promise<Vehicle[]> {
    const orgId = await this.requireOrgId();
    const rows = await this.gateway.selectList('vehicles', vehicleColumns, {
      column: 'organization_id',
      value: orgId,
      orderBy: 'created_at',
    });
    return rows.map(vehicleFromRow);
  }

  /** A plate is sealed and documents are reviewed: a change is a new registration. */
  async upsertVehicle(
    vehicle: Omit<Vehicle, 'id' | 'organizationId'> & { id?: string },
    idempotencyKey: string,
  ): Promise<Vehicle> {
    const orgId = await this.requireOrgId();
    if (vehicle.id) throw new AppError(ErrorCodes.featureUnavailable);
    const id = SupabaseGateway.asId(
      await this.gateway.rpc('register_vehicle', {
        p_idempotency_key: idempotencyKey,
        p_type: vehicle.type,
        p_plate: vehicle.plate,
        p_organization_id: orgId,
        p_assigned_worker_id: vehicle.assignedWorkerId,
        p_documents_expire_on: vehicle.documentExpiry?.toISOString().slice(0, 10),
      }),
    );
    return this.vehicle(id);
  }

  async assignVehicle(vehicleId: string, workerId: string | undefined, idempotencyKey: string): Promise<Vehicle> {
    await this.gateway.rpc('assign_vehicle', {
      p_idempotency_key: idempotencyKey,
      p_vehicle_id: vehicleId,
      p_worker_id: workerId ?? null,
    });
    return this.vehicle(vehicleId);
  }

  private async vehicle(id: string): Promise<Vehicle> {
    const row = await this.gateway.selectSingle('vehicles', vehicleColumns, 'id', id);
    if (row === null) throw new AppError(ErrorCodes.unknown);
    return vehicleFromRow(row);
  }
}
