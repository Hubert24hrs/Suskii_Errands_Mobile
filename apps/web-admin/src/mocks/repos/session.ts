// Session repository (sign-in → MFA → sliding session, reauth, sign-out,
// switchPersona demo hook) and the overview metrics repository.

import { syncServerClock } from '../../lib/serverClock';
import { SESSION_TTL_MS } from '../behavior';
import { AppError, ErrorCodes } from '../errors';
import type { AdminSession, AdminUser, CountryMetrics } from '../types';
import { MockRepo } from './base';

export interface SignedInAdmin {
  admin: AdminUser;
  session: AdminSession;
}

export class MockSessionRepository extends MockRepo {
  /**
   * Step 1: email + password. The mock accepts any password (this layer
   * simulates the post-authz backend, not credential storage) but rejects
   * unknown/inactive staff accounts. Returns an MFA challenge.
   */
  async signIn(email: string, _password: string): Promise<{ mfaRequired: true }> {
    await this.gate();
    const admin = Object.values(this.db.adminUsers).find(
      (a) => a.email.toLowerCase() === email.trim().toLowerCase(),
    );
    if (!admin || !admin.active) throw new AppError(ErrorCodes.unauthenticated);
    this.db.pendingMfaAdminId = admin.id;
    return { mfaRequired: true };
  }

  /**
   * Step 2: MFA. The mock accepts any 6-digit code (set
   * mockBehavior.failNextMfa to demo the failure path). Establishes the
   * 30-minute sliding session and syncs the simulated server clock.
   */
  async verifyMfa(code: string): Promise<SignedInAdmin> {
    await this.gate();
    const adminId = this.db.pendingMfaAdminId;
    if (!adminId) throw new AppError(ErrorCodes.invalidState);
    if (this.behavior.failNextMfa) {
      this.behavior.failNextMfa = false;
      throw new AppError(ErrorCodes.mfaInvalid);
    }
    if (!/^\d{6}$/.test(code)) throw new AppError(ErrorCodes.mfaInvalid);
    this.db.pendingMfaAdminId = null;

    syncServerClock(new Date(Date.now() + this.behavior.serverClockSkewMs));
    const session: AdminSession = {
      adminId,
      expiresAt: new Date(this.now().getTime() + SESSION_TTL_MS),
    };
    this.db.session = session;
    this.behavior.currentAdminId = adminId;
    const admin = this.db.adminUsers[adminId];
    admin.lastSignInAt = this.now();
    this.audit('session.sign_in', `admin/${adminId}`);
    return { admin, session };
  }

  /** Current signed-in admin, or null when signed out / expired. */
  async getSession(): Promise<SignedInAdmin | null> {
    await this.gate();
    try {
      const admin = this.currentAdmin;
      return { admin, session: this.session };
    } catch {
      return null;
    }
  }

  /**
   * Re-authentication for sensitive actions: refreshes reauthenticatedAt.
   * `purpose` lands in the audit log (e.g. 'approve withdrawal').
   */
  async reauth(purpose: string): Promise<AdminSession> {
    await this.gate();
    const session = this.session;
    session.reauthenticatedAt = this.now();
    this.audit('session.reauth', `admin/${session.adminId}`, purpose);
    return session;
  }

  async signOut(): Promise<void> {
    await this.gate();
    if (this.db.session) {
      this.audit('session.sign_out', `admin/${this.db.session.adminId}`);
    }
    this.db.session = null;
    this.db.pendingMfaAdminId = null;
  }

  /**
   * Demo hook: jump into another persona without the password/MFA dance
   * (mirrors the customer app's persona switcher). Still audit-logged.
   */
  async switchPersona(adminId: string): Promise<SignedInAdmin> {
    await this.gate();
    const admin = this.db.adminUsers[adminId];
    if (!admin || !admin.active) throw new AppError(ErrorCodes.unauthenticated);
    syncServerClock(new Date(Date.now() + this.behavior.serverClockSkewMs));
    const session: AdminSession = {
      adminId,
      expiresAt: new Date(this.now().getTime() + SESSION_TTL_MS),
      reauthenticatedAt: this.now(),
    };
    this.db.session = session;
    this.behavior.currentAdminId = adminId;
    this.audit('session.switch_persona', `admin/${adminId}`);
    return { admin, session };
  }
}

export class MockMetricsRepository extends MockRepo {
  /** Overview metrics for every live/beta country. */
  async getOverview(): Promise<CountryMetrics[]> {
    await this.gate();
    this.requirePermission('metrics.read');
    return Object.values(this.db.metrics);
  }
}
