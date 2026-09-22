// Admin user management: staff list, invites, role changes, activation
// toggles, MFA enforcement. Super admin only, all sensitive (reauth within
// 5 min), all audit-logged.

import { AppError, ErrorCodes } from '../errors';
import type { AdminRole, AdminUser } from '../types';
import { MockRepo } from './base';

export class MockAdminUsersRepository extends MockRepo {
  async listAdmins(): Promise<AdminUser[]> {
    await this.gate();
    this.requirePermission('adminUsers.read');
    return Object.values(this.db.adminUsers);
  }

  async invite(
    input: { name: string; email: string; role: AdminRole },
    idempotencyKey: string,
  ): Promise<AdminUser> {
    await this.gate();
    this.requireSensitive('adminUsers.manage');
    return this.idempotent('adminUsers.invite', idempotencyKey, JSON.stringify(input), () => {
      const email = input.email.trim().toLowerCase();
      const exists = Object.values(this.db.adminUsers).some(
        (a) => a.email.toLowerCase() === email,
      );
      if (exists) throw new AppError(ErrorCodes.invalidState, { details: 'email in use' });
      const admin: AdminUser = {
        id: `admin-${globalThis.crypto.randomUUID().slice(0, 8)}`,
        name: input.name,
        email,
        role: input.role,
        mfaEnrolled: false,
        active: true,
        createdAt: this.now(),
      };
      this.db.adminUsers[admin.id] = admin;
      this.audit('admin_users.invite', `admin/${admin.id}`, `${input.name} <${email}> as ${input.role}`);
      return admin;
    });
  }

  async changeRole(
    adminId: string,
    role: AdminRole,
    idempotencyKey: string,
  ): Promise<AdminUser> {
    await this.gate();
    const actor = this.requireSensitive('adminUsers.manage');
    return this.idempotent(`adminUsers.role:${adminId}`, idempotencyKey, role, () => {
      const target = this.requireAdmin(adminId);
      if (target.id === actor.id) {
        throw new AppError(ErrorCodes.invalidState, { details: 'cannot change own role' });
      }
      target.role = role;
      this.audit('admin_users.change_role', `admin/${adminId}`, `→ ${role}`);
      return target;
    });
  }

  async setActive(
    adminId: string,
    active: boolean,
    idempotencyKey: string,
  ): Promise<AdminUser> {
    await this.gate();
    const actor = this.requireSensitive('adminUsers.manage');
    return this.idempotent(`adminUsers.active:${adminId}`, idempotencyKey, String(active), () => {
      const target = this.requireAdmin(adminId);
      if (target.id === actor.id) {
        throw new AppError(ErrorCodes.invalidState, { details: 'cannot deactivate self' });
      }
      target.active = active;
      if (!active && this.db.session?.adminId === adminId) this.db.session = null;
      this.audit(
        active ? 'admin_users.activate' : 'admin_users.deactivate',
        `admin/${adminId}`,
      );
      return target;
    });
  }

  /** Enforce MFA enrolment for a staff account (policy toggle, audit-logged). */
  async enforceMfa(adminId: string, idempotencyKey: string): Promise<AdminUser> {
    await this.gate();
    this.requireSensitive('adminUsers.manage');
    return this.idempotent(`adminUsers.mfa:${adminId}`, idempotencyKey, '', () => {
      const target = this.requireAdmin(adminId);
      if (target.mfaEnrolled) throw new AppError(ErrorCodes.invalidState);
      target.mfaEnrolled = true;
      this.audit('admin_users.enforce_mfa', `admin/${adminId}`);
      return target;
    });
  }

  private requireAdmin(adminId: string): AdminUser {
    const target = this.db.adminUsers[adminId];
    if (!target) throw new AppError(ErrorCodes.unknown);
    return target;
  }
}
