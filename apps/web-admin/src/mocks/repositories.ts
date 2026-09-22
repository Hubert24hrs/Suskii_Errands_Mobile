// Mock repositories for the web admin console (M8), mirroring the
// conventions of apps/web-customer/src/mocks. Every method checks the
// role × action PERMISSION matrix server-side (hidden buttons are not
// security); sensitive actions additionally require reauth() within
// 5 minutes; sessions slide-expire after 30 minutes. Every mutating
// function takes an idempotencyKey (use newIdempotencyKey() from
// @/lib/idempotency) and writes an audit entry. Watch methods take a
// callback and return an unsubscribe function.
//
// At M9 these are replaced by Supabase-backed implementations behind the
// same signatures.

import { mockBehavior } from './behavior';
import { db } from './fixtures';
import { MockSessionRepository, MockMetricsRepository } from './repos/session';
import { MockDirectoryRepository } from './repos/directory';
import { MockVerificationRepository } from './repos/verification';
import { MockJobsRepository } from './repos/jobs';
import { MockPaymentsRepository } from './repos/payments';
import { MockReferralRepository, MockPromoRepository } from './repos/growth';
import {
  MockDisputeRepository,
  MockSupportRepository,
  MockSosRepository,
  MockRiskRepository,
} from './repos/trust';
import {
  MockConfigRepository,
  MockAnalyticsRepository,
  MockAuditRepository,
  MockAiAdminRepository,
} from './repos/config';
import { MockAdminUsersRepository } from './repos/adminUsers';

export { mockBehavior } from './behavior';
export { db, createMockDatabase, MockDatabase } from './fixtures';
export { AppError, ErrorCodes, isAppError } from './errors';
export type { ErrorCode } from './errors';
export { PERMISSIONS } from './repos/base';
export type { AdminAction, Unsubscribe } from './repos/base';
export type { DirectoryKind, DirectoryFilter } from './repos/directory';
export type { VerificationFilter } from './repos/verification';
export type { JobSearchFilter } from './repos/jobs';
export type { PaymentFilter } from './repos/payments';
export type { PromoInput } from './repos/growth';
export type { AdminConfig, ConfigChangeInput, AuditFilter } from './repos/config';
export type { SignedInAdmin } from './repos/session';

export {
  MockSessionRepository,
  MockMetricsRepository,
  MockDirectoryRepository,
  MockVerificationRepository,
  MockJobsRepository,
  MockPaymentsRepository,
  MockReferralRepository,
  MockPromoRepository,
  MockDisputeRepository,
  MockSupportRepository,
  MockSosRepository,
  MockRiskRepository,
  MockConfigRepository,
  MockAnalyticsRepository,
  MockAuditRepository,
  MockAiAdminRepository,
  MockAdminUsersRepository,
};

// Singletons over the shared seeded database. Construct your own instances
// with createMockDatabase() for isolated tests or demo resets.
export const sessionRepository = new MockSessionRepository(db, mockBehavior);
export const metricsRepository = new MockMetricsRepository(db, mockBehavior);
export const directoryRepository = new MockDirectoryRepository(db, mockBehavior);
export const verificationRepository = new MockVerificationRepository(db, mockBehavior);
export const jobsRepository = new MockJobsRepository(db, mockBehavior);
export const paymentsRepository = new MockPaymentsRepository(db, mockBehavior);
export const referralRepository = new MockReferralRepository(db, mockBehavior);
export const promoRepository = new MockPromoRepository(db, mockBehavior);
export const disputeRepository = new MockDisputeRepository(db, mockBehavior);
export const supportRepository = new MockSupportRepository(db, mockBehavior);
export const sosRepository = new MockSosRepository(db, mockBehavior);
export const riskRepository = new MockRiskRepository(db, mockBehavior);
export const configRepository = new MockConfigRepository(db, mockBehavior);
export const analyticsRepository = new MockAnalyticsRepository(db, mockBehavior);
export const auditRepository = new MockAuditRepository(db, mockBehavior);
export const aiAdminRepository = new MockAiAdminRepository(db, mockBehavior);
export const adminUsersRepository = new MockAdminUsersRepository(db, mockBehavior);
