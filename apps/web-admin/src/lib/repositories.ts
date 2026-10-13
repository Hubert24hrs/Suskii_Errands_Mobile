// Repository seam for the admin console. Every screen imports repositories from here,
// never from '@/mocks/repositories' directly — the same rule as apps/web-customer.
//
// The mocks stay the default; every repository switches to its Supabase implementation
// when NEXT_PUBLIC_SUPABASE_URL and NEXT_PUBLIC_SUPABASE_ANON_KEY are set. Sign-in then
// needs a real staff account and its authenticator app (aal2), because every admin
// function on the backend refuses anything less.

import {
  adminUsersRepository as mockAdminUsersRepository,
  aiAdminRepository as mockAiAdminRepository,
  analyticsRepository as mockAnalyticsRepository,
  auditRepository as mockAuditRepository,
  configRepository as mockConfigRepository,
  directoryRepository as mockDirectoryRepository,
  disputeRepository as mockDisputeRepository,
  jobsRepository as mockJobsRepository,
  metricsRepository as mockMetricsRepository,
  paymentsRepository as mockPaymentsRepository,
  promoRepository as mockPromoRepository,
  referralRepository as mockReferralRepository,
  riskRepository as mockRiskRepository,
  sessionRepository as mockSessionRepository,
  sosRepository as mockSosRepository,
  supportRepository as mockSupportRepository,
  verificationRepository as mockVerificationRepository,
} from '@/mocks/repositories';

import { SupabaseAdminUsersRepository } from './supabase/adminUsersRepository';
import {
  SupabaseAiAdminRepository,
  SupabaseAnalyticsRepository,
  SupabaseAuditRepository,
  SupabaseConfigRepository,
} from './supabase/configRepository';
import { SupabaseDirectoryRepository } from './supabase/directoryRepository';
import { SupabaseGateway } from './supabase/gateway';
import { SupabasePromoRepository, SupabaseReferralRepository } from './supabase/growthRepository';
import { SupabaseJobsRepository } from './supabase/jobsRepository';
import { SupabasePaymentsRepository } from './supabase/paymentsRepository';
import { SupabaseMetricsRepository, SupabaseSessionRepository } from './supabase/sessionRepository';
import {
  SupabaseDisputeRepository,
  SupabaseRiskRepository,
  SupabaseSosRepository,
  SupabaseSupportRepository,
} from './supabase/trustRepository';
import { SupabaseVerificationRepository } from './supabase/verificationRepository';

export { AppError, ErrorCodes, isAppError, PERMISSIONS } from '@/mocks/repositories';
export type {
  AdminAction,
  AdminConfig,
  AuditFilter,
  CampaignInput,
  ConfigChangeInput,
  DirectoryFilter,
  DirectoryKind,
  ErrorCode,
  JobSearchFilter,
  PaymentFilter,
  PromoInput,
  SignedInAdmin,
  Unsubscribe,
  VerificationFilter,
} from '@/mocks/repositories';
export type { TotpEnrolment } from './supabase/sessionRepository';

/** Null unless the build has Supabase config. */
export const supabaseGateway = SupabaseGateway.fromEnv();

/** True when the console talks to the real backend rather than the demo mocks. */
export const usingRealBackend = supabaseGateway !== null;

/**
 * Against the real backend, campaigns, promos and staff access change only when a second
 * super admin signs, so the screens say "sent for approval" rather than "done".
 */
export const changesNeedSecondApproval = usingRealBackend;

const gw = supabaseGateway;

export const sessionRepository = gw ? new SupabaseSessionRepository(gw) : mockSessionRepository;
export const metricsRepository = gw ? new SupabaseMetricsRepository(gw) : mockMetricsRepository;
export const directoryRepository = gw
  ? new SupabaseDirectoryRepository(gw)
  : mockDirectoryRepository;
export const verificationRepository = gw
  ? new SupabaseVerificationRepository(gw)
  : mockVerificationRepository;
export const jobsRepository = gw ? new SupabaseJobsRepository(gw) : mockJobsRepository;
export const paymentsRepository = gw ? new SupabasePaymentsRepository(gw) : mockPaymentsRepository;
export const referralRepository = gw ? new SupabaseReferralRepository(gw) : mockReferralRepository;
export const promoRepository = gw ? new SupabasePromoRepository(gw) : mockPromoRepository;
export const disputeRepository = gw ? new SupabaseDisputeRepository(gw) : mockDisputeRepository;
export const supportRepository = gw ? new SupabaseSupportRepository(gw) : mockSupportRepository;
export const sosRepository = gw ? new SupabaseSosRepository(gw) : mockSosRepository;
export const riskRepository = gw ? new SupabaseRiskRepository(gw) : mockRiskRepository;
export const configRepository = gw ? new SupabaseConfigRepository(gw) : mockConfigRepository;
export const analyticsRepository = gw
  ? new SupabaseAnalyticsRepository(gw)
  : mockAnalyticsRepository;
export const auditRepository = gw ? new SupabaseAuditRepository(gw) : mockAuditRepository;
export const aiAdminRepository = gw ? new SupabaseAiAdminRepository(gw) : mockAiAdminRepository;
export const adminUsersRepository = gw
  ? new SupabaseAdminUsersRepository(gw)
  : mockAdminUsersRepository;
