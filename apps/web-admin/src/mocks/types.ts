// Admin-scope types for the M8 internal console mock layer. Shapes mirror the
// official contracts style from packages/suskii_domain / apps/web-customer:
// Money is always integer minor units + ISO 4217, derived amounts arrive as
// server-style quote objects, and the client never computes them.

import type { MoneyLike } from '../lib/money';

export type Money = MoneyLike;

export interface GeoPoint {
  latitude: number;
  longitude: number;
}

// ---------------------------------------------------------------------------
// Session & staff
// ---------------------------------------------------------------------------

export type AdminRole =
  | 'super_admin'
  | 'verification_officer'
  | 'support_agent'
  | 'finance_officer'
  | 'dispute_officer';

export interface AdminUser {
  id: string;
  name: string;
  email: string;
  role: AdminRole;
  mfaEnrolled: boolean;
  active: boolean;
  createdAt: Date;
  lastSignInAt?: Date;
}

export interface AdminSession {
  adminId: string;
  /** 30-minute sliding expiry, checked on every call (ERR_SESSION_EXPIRED). */
  expiresAt: Date;
  /** Set by reauth(); sensitive mutations require this to be < 5 min old. */
  reauthenticatedAt?: Date;
}

// ---------------------------------------------------------------------------
// Overview metrics
// ---------------------------------------------------------------------------

export interface CountryMetrics {
  country: string;
  currency: string;
  dau: number;
  activeJobs: number;
  offersPerRequest: number;
  gmv: Money;
  holdBalance: Money;
  openDisputes: number;
  openSos: number;
}

// ---------------------------------------------------------------------------
// Directory (users / providers / businesses / workers / vehicles)
// ---------------------------------------------------------------------------

export type ManagedStatus = 'active' | 'suspended';
export type TrustLevel = 'new' | 'established' | 'trusted' | 'flagged';
export type VerificationStatus = 'unverified' | 'pending' | 'verified' | 'rejected';

export interface SuspensionRecord {
  reason: string;
  byAdminId: string;
  at: Date;
}

export interface ManagedUser {
  id: string;
  name: string;
  phone: string;
  country: string;
  status: ManagedStatus;
  trustLevel: TrustLevel;
  verificationStatus: VerificationStatus;
  jobsCount: number;
  totalSpend: Money;
  joinedAt: Date;
  suspension?: SuspensionRecord;
}

export interface ManagedProvider {
  id: string;
  name: string;
  phone: string;
  country: string;
  status: ManagedStatus;
  trustLevel: TrustLevel;
  verificationStatus: VerificationStatus;
  rating: number;
  completedJobs: number;
  businessId?: string;
  joinedAt: Date;
  suspension?: SuspensionRecord;
}

export interface ManagedBusiness {
  id: string;
  name: string;
  registrationNumber: string;
  country: string;
  status: ManagedStatus;
  verificationStatus: VerificationStatus;
  providerIds: string[];
  joinedAt: Date;
  suspension?: SuspensionRecord;
}

export interface ManagedWorker {
  id: string;
  name: string;
  businessId: string;
  role: string;
  status: ManagedStatus;
  verificationStatus: VerificationStatus;
  suspension?: SuspensionRecord;
}

export interface ManagedVehicle {
  id: string;
  plate: string;
  make: string;
  model: string;
  ownerProviderId: string;
  status: ManagedStatus;
  verificationStatus: VerificationStatus;
  suspension?: SuspensionRecord;
}

// ---------------------------------------------------------------------------
// Verification queues
// ---------------------------------------------------------------------------

export type VerificationKind =
  | 'id_document'
  | 'facial'
  | 'police_clearance'
  | 'vehicle_document'
  | 'business_document';

export type VerificationQueueStatus = 'queued' | 'in_review' | 'approved' | 'rejected';

export interface VerificationQueueItem {
  id: string;
  kind: VerificationKind;
  /** Who/what is being verified. */
  subjectType: 'user' | 'provider' | 'business' | 'worker' | 'vehicle';
  subjectId: string;
  subjectName: string;
  country: string;
  submittedAt: Date;
  status: VerificationQueueStatus;
  priority: 'normal' | 'high';
  claimedByAdminId?: string;
  reviewedAt?: Date;
  /** Rejection reason key (localization key, never raw text). */
  decisionReasonKey?: string;
}

/** Short-lived (60s) document viewing grant. Every issue is audit-logged. */
export interface DocumentViewGrant {
  itemId: string;
  viewToken: string;
  /** Opaque URL — no stable deep link to the document bytes. */
  url: string;
  expiresAt: Date;
}

// ---------------------------------------------------------------------------
// Jobs (requests / offers / timeline / map)
// ---------------------------------------------------------------------------

export type JobStatus =
  | 'draft'
  | 'negotiating'
  | 'agreed'
  | 'payment_pending'
  | 'paid_held'
  | 'in_progress'
  | 'completed_by_provider'
  | 'confirmed'
  | 'disputed'
  | 'refunded'
  | 'cancelled';

export interface JobTimelineEvent {
  status: JobStatus | 'created';
  at: Date;
  actor: 'customer' | 'provider' | 'system' | 'admin';
  note?: string;
}

export interface JobAdminView {
  id: string;
  title: string;
  categoryId: string;
  country: string;
  customerId: string;
  customerName: string;
  providerId?: string;
  providerName?: string;
  status: JobStatus;
  agreedPrice?: Money;
  offersCount: number;
  createdAt: Date;
  timeline: JobTimelineEvent[];
  /** Approximate route polyline for the live map (origin → destination). */
  routePoints: GeoPoint[];
  /** Latest known courier position while in_progress. */
  livePosition?: GeoPoint;
}

// ---------------------------------------------------------------------------
// Payments (holds / settlements / payouts / withdrawals)
// ---------------------------------------------------------------------------

export type PaymentAdminKind = 'hold' | 'settlement' | 'payout' | 'withdrawal';

export type PaymentAdminStatus =
  | 'held'
  | 'pending'
  | 'processing'
  | 'completed'
  | 'failed'
  | 'refunded';

export type ApprovalState =
  | 'none'
  | 'single_pending'
  | 'awaiting_second'
  | 'approved'
  | 'rejected';

export interface ApprovalRecord {
  state: ApprovalState;
  /** Admins who have approved so far, in order. */
  approverIds: string[];
  rejectedByAdminId?: string;
  requestedAt?: Date;
  decidedAt?: Date;
}

export interface PaymentAdminView {
  id: string;
  kind: PaymentAdminKind;
  country: string;
  /** Counterparty: job id for holds/settlements, provider id for payouts,
   *  provider/business id for withdrawals. */
  referenceId: string;
  counterpartyName: string;
  /** Server-computed breakdown — the admin console displays, never derives. */
  quote: {
    gross: Money;
    platformCommission?: Money;
    net: Money;
  };
  status: PaymentAdminStatus;
  approval: ApprovalRecord;
  createdAt: Date;
}

// ---------------------------------------------------------------------------
// Referrals
// ---------------------------------------------------------------------------

export interface ReferralAttribution {
  id: string;
  referrerId: string;
  referrerName: string;
  refereeId: string;
  refereeName: string;
  country: string;
  attributedAt: Date;
  qualifyingJobs: number;
  /** Total commission earned by the referrer from this referee (server-set). */
  commissionEarned: Money;
}

export type ReferralFlagReason =
  | 'self_referral_suspected'
  | 'device_cluster'
  | 'velocity_abuse'
  | 'payment_reuse';

export interface ReferralFlaggedCase {
  id: string;
  attributionId: string;
  reason: ReferralFlagReason;
  signals: string[];
  flaggedAt: Date;
  status: 'open' | 'dismissed' | 'confirmed_abuse';
  reviewedByAdminId?: string;
}

export interface ReferralCampaign {
  id: string;
  name: string;
  country: string;
  /** Server-set reward amounts. */
  referrerReward: Money;
  refereeReward: Money;
  status: 'active' | 'paused' | 'ended';
  startsAt: Date;
  endsAt?: Date;
}

// ---------------------------------------------------------------------------
// Promos
// ---------------------------------------------------------------------------

export interface PromoCampaign {
  id: string;
  code: string;
  country: string;
  /** Percentage off (0–100); caps and budgets are server-set Money. */
  discountPercent: number;
  maxDiscount?: Money;
  budget: Money;
  spent: Money;
  maxRedemptions: number;
  redemptions: number;
  status: 'draft' | 'active' | 'paused' | 'expired';
  startsAt: Date;
  endsAt: Date;
}

// ---------------------------------------------------------------------------
// Disputes
// ---------------------------------------------------------------------------

export interface DisputeEvidenceRef {
  id: string;
  kind: 'photo' | 'chat_excerpt' | 'location_log' | 'payment_record';
  label: string;
  uploadedBy: 'customer' | 'provider' | 'system';
  uploadedAt: Date;
}

export type DisputeResolutionAction =
  | 'refund_full'
  | 'refund_partial'
  | 'release_to_provider'
  | 'reject';

export type DisputeCaseStatus = 'open' | 'in_review' | 'resolved' | 'rejected';

export interface DisputeCase {
  id: string;
  jobId: string;
  country: string;
  customerId: string;
  customerName: string;
  providerId: string;
  providerName: string;
  reasonKey: string;
  status: DisputeCaseStatus;
  openedAt: Date;
  assignedToAdminId?: string;
  evidence: DisputeEvidenceRef[];
  /** Held amount in escrow — input to the resolution quote. */
  heldAmount: Money;
  resolution?: {
    action: DisputeResolutionAction;
    quote: DisputeResolutionQuote;
    byAdminId: string;
    at: Date;
  };
}

/**
 * Server-computed resolution quote: the admin picks an action (and for
 * partial refunds a percentage), the server returns exact amounts.
 */
export interface DisputeResolutionQuote {
  action: DisputeResolutionAction;
  refundToCustomer: Money;
  releaseToProvider: Money;
  platformRetained: Money;
}

// ---------------------------------------------------------------------------
// Support tickets
// ---------------------------------------------------------------------------

export interface SupportTicketMessage {
  id: string;
  author: 'customer' | 'agent' | 'ai';
  body: string;
  at: Date;
}

export interface SupportTicketAdmin {
  id: string;
  userId: string;
  userName: string;
  country: string;
  subject: string;
  status: 'open' | 'assigned' | 'closed';
  priority: 'low' | 'normal' | 'high';
  assignedToAdminId?: string;
  createdAt: Date;
  messages: SupportTicketMessage[];
}

// ---------------------------------------------------------------------------
// SOS operations
// ---------------------------------------------------------------------------

export type SosStatus = 'active' | 'acknowledged' | 'resolved';

export interface SosLocationPing {
  at: Date;
  point: GeoPoint;
}

export interface SosAlertAdmin {
  id: string;
  jobId: string;
  country: string;
  triggeredBy: 'customer' | 'provider';
  userName: string;
  userPhone: string;
  status: SosStatus;
  triggeredAt: Date;
  acknowledgedByAdminId?: string;
  acknowledgedAt?: Date;
  resolvedAt?: Date;
  resolutionNote?: string;
  /** Location trail, newest last; active alerts keep ticking via watchSos. */
  trail: SosLocationPing[];
}

// ---------------------------------------------------------------------------
// Risk & fraud
// ---------------------------------------------------------------------------

export type RiskCaseKind =
  | 'payment_fraud'
  | 'account_takeover'
  | 'collusion'
  | 'incentive_abuse'
  | 'identity_mismatch';

export interface RiskCase {
  id: string;
  kind: RiskCaseKind;
  country: string;
  subjectUserId: string;
  subjectName: string;
  signals: string[];
  status: 'open' | 'reviewed' | 'escalated';
  openedAt: Date;
  reviewedByAdminId?: string;
}

// ---------------------------------------------------------------------------
// Config (feature flags / country packs / commissions) with approval flow
// ---------------------------------------------------------------------------

export interface FeatureFlag {
  key: string;
  description: string;
  enabled: boolean;
  /** Countries where enabled (empty = global). */
  countries: string[];
}

export interface CountryPackConfig {
  country: string;
  currency: string;
  live: boolean;
  categories: string[];
  supportPhone: string;
}

export interface CommissionConfig {
  country: string;
  /** Basis points (1250 = 12.5%). */
  rateBps: number;
  effectiveFrom: Date;
}

export type ConfigChangeStatus = 'proposed' | 'approved' | 'rejected';

export interface ConfigChange {
  id: string;
  target: 'feature_flag' | 'country_pack' | 'commission';
  targetKey: string;
  /** Human-readable summary of the proposed value(s). */
  summary: string;
  proposedValue: Record<string, unknown>;
  proposedByAdminId: string;
  proposedAt: Date;
  status: ConfigChangeStatus;
  decidedByAdminId?: string;
  decidedAt?: Date;
}

// ---------------------------------------------------------------------------
// Analytics
// ---------------------------------------------------------------------------

export type AnalyticsMetric =
  | 'gmv'
  | 'jobs_completed'
  | 'dau'
  | 'dispute_rate'
  | 'offer_acceptance_rate';

export interface AnalyticsPoint {
  date: string; // ISO yyyy-mm-dd
  value: number;
}

export interface AnalyticsSeries {
  metric: AnalyticsMetric;
  country: string;
  currency: string;
  points: AnalyticsPoint[];
}

// ---------------------------------------------------------------------------
// Audit log
// ---------------------------------------------------------------------------

export interface AuditLogEntry {
  id: string;
  actorAdminId: string;
  actorName: string;
  action: string;
  target: string;
  reason?: string;
  at: Date;
}

// ---------------------------------------------------------------------------
// AI Admin Assistant (read-only)
// ---------------------------------------------------------------------------

export interface AiProposedAction {
  /** Deep-link target inside the console, e.g. '/disputes/disp-1'. */
  module: string;
  targetId?: string;
  label: string;
  rationale: string;
}

export interface AiAdminMessage {
  id: string;
  role: 'admin' | 'assistant';
  body: string;
  at: Date;
  /** Assistant-only: cards linking to modules. Never mutates anything. */
  proposedActions?: AiProposedAction[];
}
