// Staff. Listing reads admin_staff_list; every change to somebody's access — inviting,
// a new role, switching an account off — is a four-eyes proposal (RLS matrix §6:
// "admin role grants"), and nobody may propose or sign a change to their own.

import { AppError, ErrorCodes } from '@/mocks/errors';
import type { AdminRole, AdminUser } from '@/mocks/types';

import { SupabaseAdminRepo, parseRoles, primaryRole } from './base';
import { SupabaseGateway, type Row } from './gateway';
import { propose } from './proposals';

function staff(row: Row): AdminUser {
  const roles = parseRoles(row['roles']);
  return {
    id: String(row['user_id']),
    name: String(row['display_name'] ?? row['email'] ?? ''),
    email: String(row['email'] ?? ''),
    role: primaryRole(roles),
    roles,
    mfaEnrolled: Boolean(row['mfa_enrolled']),
    active: row['disabled_at'] === null || row['disabled_at'] === undefined,
    createdAt: SupabaseGateway.asTimestamp(row['created_at']),
    lastSignInAt: SupabaseGateway.asOptionalTimestamp(row['last_sign_in_at']),
  };
}

export class SupabaseAdminUsersRepository extends SupabaseAdminRepo {
  async listAdmins(): Promise<AdminUser[]> {
    return (await this.gw.rpcRows('admin_staff_list')).map(staff);
  }

  /**
   * The person signs up first; this finds their account by exact email and proposes the
   * role. Until a second super admin signs, they are not staff.
   */
  async invite(
    input: { name: string; email: string; role: AdminRole },
    idempotencyKey: string,
  ): Promise<AdminUser> {
    await this.requireRecentMfa('adminUsers.manage');
    const found = SupabaseAdminRepo.first(
      await this.gw.rpcRows('admin_staff_lookup', { p_email: input.email.trim() }),
    );
    await propose(this.gw, idempotencyKey, 'admin_user', String(found['user_id']),
      { roles: [input.role], active: true }, undefined, `Invite ${input.name}`);
    return {
      id: String(found['user_id']),
      name: String(found['display_name'] ?? input.name),
      email: String(found['email'] ?? input.email),
      role: input.role,
      roles: [input.role],
      mfaEnrolled: false,
      active: false,
      createdAt: new Date(),
    };
  }

  async changeRole(adminId: string, role: AdminRole, idempotencyKey: string): Promise<AdminUser> {
    await this.requireRecentMfa('adminUsers.manage');
    await propose(this.gw, idempotencyKey, 'admin_user', adminId, { roles: [role] });
    return this.find(adminId);
  }

  async setActive(adminId: string, active: boolean, idempotencyKey: string): Promise<AdminUser> {
    await this.requireRecentMfa('adminUsers.manage');
    await propose(this.gw, idempotencyKey, 'admin_user', adminId, { active });
    return this.find(adminId);
  }

  /** Every admin function requires aal2, so a second factor is already mandatory for all staff. */
  async enforceMfa(_adminId: string, _idempotencyKey: string): Promise<AdminUser> {
    throw new AppError(ErrorCodes.featureUnavailable);
  }

  private async find(adminId: string): Promise<AdminUser> {
    const admin = (await this.listAdmins()).find((a) => a.id === adminId);
    if (!admin) throw new AppError(ErrorCodes.notFound);
    return admin;
  }
}
