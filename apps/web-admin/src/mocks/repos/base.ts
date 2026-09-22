// Shared base for the admin mock repositories: behavior gate, idempotency
// store, server clock, session enforcement (30-min sliding expiry), the
// role × action PERMISSION matrix, reauth windows for sensitive actions,
// and the audit-write helper every mutation goes through.

import { serverNow } from '../../lib/serverClock';
import {
  gate,
  IdempotencyStore,
  REAUTH_WINDOW_MS,
  SESSION_TTL_MS,
  type MockBehavior,
} from '../behavior';
import { AppError, ErrorCodes } from '../errors';
import type { MockDatabase } from '../fixtures';
import type { AdminRole, AdminSession, AdminUser } from '../types';

/** Unsubscribe handle returned by every watch* method. */
export type Unsubscribe = () => void;

/**
 * Every permission-checked action in the console. Hidden buttons are not
 * security: each repo method calls requirePermission() on the server side
 * (this mock) before doing anything.
 */
export type AdminAction =
  // Reads
  | 'metrics.read'
  | 'directory.read'
  | 'verification.read'
  | 'jobs.read'
  | 'payments.read'
  | 'referrals.read'
  | 'promos.read'
  | 'disputes.read'
  | 'support.read'
  | 'sos.read'
  | 'risk.read'
  | 'config.read'
  | 'analytics.read'
  | 'audit.read'
  | 'adminUsers.read'
  | 'aiAdmin.use'
  // Mutations
  | 'directory.suspend'
  | 'verification.claim'
  | 'verification.review'
  | 'verification.view_document'
  | 'payments.approve'
  | 'referrals.manage'
  | 'promos.manage'
  | 'disputes.resolve'
  | 'support.manage'
  | 'sos.manage'
  | 'risk.review'
  | 'config.propose'
  | 'config.approve'
  | 'adminUsers.manage';

const ALL: AdminRole[] = [
  'super_admin',
  'verification_officer',
  'support_agent',
  'finance_officer',
  'dispute_officer',
];

/** The role × action matrix. super_admin is explicitly listed everywhere. */
export const PERMISSIONS: Record<AdminAction, AdminRole[]> = {
  'metrics.read': ALL,
  'directory.read': ALL,
  'verification.read': ['super_admin', 'verification_officer'],
  'jobs.read': ALL,
  'payments.read': ['super_admin', 'finance_officer'],
  'referrals.read': ['super_admin', 'support_agent'],
  'promos.read': ['super_admin', 'support_agent'],
  'disputes.read': ['super_admin', 'dispute_officer', 'support_agent'],
  'support.read': ['super_admin', 'support_agent'],
  'sos.read': ['super_admin', 'support_agent'],
  'risk.read': ['super_admin', 'dispute_officer'],
  'config.read': ['super_admin', 'finance_officer'],
  'analytics.read': ALL,
  'audit.read': ['super_admin'],
  'adminUsers.read': ['super_admin'],
  'aiAdmin.use': ALL,

  'directory.suspend': ['super_admin', 'support_agent'],
  'verification.claim': ['super_admin', 'verification_officer'],
  'verification.review': ['super_admin', 'verification_officer'],
  'verification.view_document': ['super_admin', 'verification_officer'],
  'payments.approve': ['super_admin', 'finance_officer'],
  'referrals.manage': ['super_admin', 'support_agent'],
  'promos.manage': ['super_admin', 'support_agent'],
  'disputes.resolve': ['super_admin', 'dispute_officer'],
  'support.manage': ['super_admin', 'support_agent'],
  'sos.manage': ['super_admin', 'support_agent'],
  'risk.review': ['super_admin', 'dispute_officer'],
  'config.propose': ['super_admin', 'finance_officer'],
  'config.approve': ['super_admin', 'finance_officer'],
  'adminUsers.manage': ['super_admin'],
};

/**
 * Actions that additionally require reauth() within the last 5 minutes
 * (approvals, resolutions, config changes, admin-user changes, document
 * views). ERR_REAUTH_REQUIRED otherwise.
 */
const SENSITIVE: ReadonlySet<AdminAction> = new Set([
  'verification.view_document',
  'payments.approve',
  'disputes.resolve',
  'config.propose',
  'config.approve',
  'adminUsers.manage',
]);

export abstract class MockRepo {
  constructor(
    protected readonly db: MockDatabase,
    protected readonly behavior: MockBehavior,
  ) {}

  protected gate(): Promise<void> {
    return gate();
  }

  private readonly idempotency = new IdempotencyStore();

  /**
   * Runs a mutating call under an idempotency key. Same key + same argsHash
   * replays the stored result; same key + different argsHash throws
   * ERR_IDEMPOTENCY_KEY_REUSED.
   */
  protected idempotent<T>(
    operation: string,
    key: string,
    argsHash: string,
    run: () => Promise<T> | T,
  ): Promise<T> {
    return this.idempotency.run(operation, key, argsHash, run);
  }

  /** The simulated server clock — TTLs are always computed against this. */
  protected now(): Date {
    return serverNow();
  }

  /**
   * The current session, enforcing the 30-minute sliding expiry on every
   * call. Expired sessions are destroyed and fail with ERR_SESSION_EXPIRED.
   */
  protected get session(): AdminSession {
    const s = this.db.session;
    if (!s) throw new AppError(ErrorCodes.unauthenticated);
    const now = this.now();
    if (s.expiresAt.getTime() <= now.getTime()) {
      this.db.session = null;
      throw new AppError(ErrorCodes.sessionExpired);
    }
    s.expiresAt = new Date(now.getTime() + SESSION_TTL_MS);
    return s;
  }

  protected get currentAdmin(): AdminUser {
    const session = this.session;
    const admin = this.db.adminUsers[session.adminId];
    if (!admin || !admin.active) throw new AppError(ErrorCodes.unauthenticated);
    return admin;
  }

  /** Role check — every repo method starts here. */
  protected requirePermission(action: AdminAction): AdminUser {
    const admin = this.currentAdmin;
    if (!PERMISSIONS[action].includes(admin.role)) {
      throw new AppError(ErrorCodes.permissionDenied, {
        details: { action, role: admin.role },
      });
    }
    return admin;
  }

  /**
   * Permission + the 5-minute reauth window for sensitive actions
   * (SENSITIVE set). Returns the acting admin.
   */
  protected requireSensitive(action: AdminAction): AdminUser {
    const admin = this.requirePermission(action);
    if (SENSITIVE.has(action)) {
      const s = this.session;
      const sinceReauth = s.reauthenticatedAt
        ? this.now().getTime() - s.reauthenticatedAt.getTime()
        : Number.POSITIVE_INFINITY;
      if (sinceReauth > REAUTH_WINDOW_MS) {
        throw new AppError(ErrorCodes.reauthRequired, {
          details: { action },
        });
      }
    }
    return admin;
  }

  /** Append-only audit write; every mutation calls this before returning. */
  protected audit(action: string, target: string, reason?: string): void {
    this.db.appendAudit(this.currentAdmin, action, target, reason);
  }
}
