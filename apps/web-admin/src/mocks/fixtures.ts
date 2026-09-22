// In-memory mock "database" for the admin console, seeded with realistic
// fixtures: one persona per admin role, three countries of metrics, mixed
// directory entities, verification queues in every kind/status, jobs with
// timelines + route points, payments across kinds (incl. a withdrawal
// awaiting second approval), flagged referrals, promos, disputes with
// evidence, support tickets, live + acknowledged SOS alerts, risk cases,
// config with a pending approval, 30-day analytics, and audit entries.

import { Emitter, roundHalfEven } from './behavior';
import type {
  AdminUser,
  AdminSession,
  AiAdminMessage,
  AnalyticsSeries,
  AnalyticsMetric,
  AuditLogEntry,
  CommissionConfig,
  ConfigChange,
  CountryMetrics,
  CountryPackConfig,
  DisputeCase,
  DocumentViewGrant,
  FeatureFlag,
  JobAdminView,
  JobTimelineEvent,
  JobStatus,
  ManagedBusiness,
  ManagedProvider,
  ManagedUser,
  ManagedVehicle,
  ManagedWorker,
  Money,
  PaymentAdminView,
  PromoCampaign,
  ReferralAttribution,
  ReferralCampaign,
  ReferralFlaggedCase,
  RiskCase,
  SosAlertAdmin,
  SupportTicketAdmin,
  VerificationQueueItem,
} from './types';

function minutesAgo(n: number): Date {
  return new Date(Date.now() - n * 60_000);
}
function hoursAgo(n: number): Date {
  return new Date(Date.now() - n * 3_600_000);
}
function daysAgo(n: number): Date {
  return new Date(Date.now() - n * 86_400_000);
}

function money(amountMinor: number, currency: string): Money {
  return { amountMinor, currency };
}

/** Server-style quote: commission rounded half-even, net = gross − commission. */
function quote(amountMinor: number, currency: string, rateBps: number) {
  const gross = money(amountMinor, currency);
  const commission = money(roundHalfEven(amountMinor * rateBps, 10000), currency);
  return {
    gross,
    platformCommission: commission,
    net: money(amountMinor - commission.amountMinor, currency),
  };
}

/** Deterministic pseudo-random in [0,1) from a string seed + index (LCG). */
function seededValue(seed: string, index: number): number {
  let h = 2166136261;
  for (let i = 0; i < seed.length; i++) {
    h = (h ^ seed.charCodeAt(i)) * 16777619;
  }
  h = (h + index * 2654435761) | 0;
  h = Math.imul(h ^ (h >>> 13), 1274126177);
  return ((h ^ (h >>> 16)) >>> 0) / 4294967296;
}

function timeline(
  created: Date,
  stages: Array<[JobStatus | 'created', 'customer' | 'provider' | 'system' | 'admin', number]>,
): JobTimelineEvent[] {
  return stages.map(([status, actor, minutesAfter]) => ({
    status,
    actor,
    at: new Date(created.getTime() + minutesAfter * 60_000),
  }));
}

export class MockDatabase {
  // Staff & session
  adminUsers: Record<string, AdminUser> = {};
  session: AdminSession | null = null;
  /** Admin id awaiting the MFA step after password sign-in. */
  pendingMfaAdminId: string | null = null;

  // Overview
  metrics: Record<string, CountryMetrics> = {};

  // Directory
  users: Record<string, ManagedUser> = {};
  providers: Record<string, ManagedProvider> = {};
  businesses: Record<string, ManagedBusiness> = {};
  workers: Record<string, ManagedWorker> = {};
  vehicles: Record<string, ManagedVehicle> = {};

  // Verification
  verificationQueue: Record<string, VerificationQueueItem> = {};
  /** Document view grants by viewToken. */
  documentViewGrants: Record<string, DocumentViewGrant> = {};

  // Operations
  jobs: Record<string, JobAdminView> = {};
  payments: Record<string, PaymentAdminView> = {};

  // Growth
  referralAttributions: Record<string, ReferralAttribution> = {};
  referralFlags: Record<string, ReferralFlaggedCase> = {};
  referralCampaigns: Record<string, ReferralCampaign> = {};
  promos: Record<string, PromoCampaign> = {};

  // Trust & safety
  disputes: Record<string, DisputeCase> = {};
  tickets: Record<string, SupportTicketAdmin> = {};
  sosAlerts: Record<string, SosAlertAdmin> = {};
  riskCases: Record<string, RiskCase> = {};

  // Config
  featureFlags: Record<string, FeatureFlag> = {};
  countryPackConfigs: Record<string, CountryPackConfig> = {};
  commissionConfigs: Record<string, CommissionConfig> = {};
  configChanges: Record<string, ConfigChange> = {};

  // Insight
  analytics: AnalyticsSeries[] = [];
  auditLog: AuditLogEntry[] = [];
  aiChat: AiAdminMessage[] = [];

  // Streams
  sosEvents = new Emitter<SosAlertAdmin>();
  auditEvents = new Emitter<AuditLogEntry>();

  private auditSeq = 0;

  /** Append-only audit write — every mutation in the repos goes through this. */
  appendAudit(
    actor: AdminUser,
    action: string,
    target: string,
    reason?: string,
    at?: Date,
  ): AuditLogEntry {
    const entry: AuditLogEntry = {
      id: `audit-${++this.auditSeq}-${Date.now()}`,
      actorAdminId: actor.id,
      actorName: actor.name,
      action,
      target,
      reason,
      at: at ?? new Date(),
    };
    this.auditLog.push(entry);
    this.auditEvents.emit(entry);
    return entry;
  }
}

export function createMockDatabase(): MockDatabase {
  const db = new MockDatabase();

  // ---------------------------------------------------------------- staff
  const staff: AdminUser[] = [
    { id: 'admin-amina', name: 'Amina Yusuf', email: 'amina@suskii.africa', role: 'super_admin', mfaEnrolled: true, active: true, createdAt: daysAgo(400) },
    { id: 'admin-femi', name: 'Femi Adebayo', email: 'femi@suskii.africa', role: 'verification_officer', mfaEnrolled: true, active: true, createdAt: daysAgo(300) },
    { id: 'admin-kojo', name: 'Kojo Mensah', email: 'kojo@suskii.africa', role: 'support_agent', mfaEnrolled: true, active: true, createdAt: daysAgo(280) },
    { id: 'admin-zainab', name: 'Zainab Bello', email: 'zainab@suskii.africa', role: 'finance_officer', mfaEnrolled: true, active: true, createdAt: daysAgo(260) },
    { id: 'admin-sola', name: 'Sola Ogunleye', email: 'sola@suskii.africa', role: 'dispute_officer', mfaEnrolled: false, active: true, createdAt: daysAgo(120) },
  ];
  for (const s of staff) db.adminUsers[s.id] = s;

  // -------------------------------------------------------------- metrics
  db.metrics = {
    NG: { country: 'NG', currency: 'NGN', dau: 12480, activeJobs: 342, offersPerRequest: 2.7, gmv: money(4_852_000_000, 'NGN'), holdBalance: money(620_000_000, 'NGN'), openDisputes: 7, openSos: 1 },
    KE: { country: 'KE', currency: 'KES', dau: 5210, activeJobs: 128, offersPerRequest: 2.3, gmv: money(984_000_000, 'KES'), holdBalance: money(145_000_000, 'KES'), openDisputes: 3, openSos: 0 },
    GH: { country: 'GH', currency: 'GHS', dau: 3480, activeJobs: 86, offersPerRequest: 2.1, gmv: money(61_000_000, 'GHS'), holdBalance: money(8_900_000, 'GHS'), openDisputes: 2, openSos: 0 },
  };

  // ------------------------------------------------------------ directory
  const users: ManagedUser[] = [
    { id: 'mu-1', name: 'Ada Okafor', phone: '+2348010000001', country: 'NG', status: 'active', trustLevel: 'trusted', verificationStatus: 'verified', jobsCount: 34, totalSpend: money(8_450_000, 'NGN'), joinedAt: daysAgo(210) },
    { id: 'mu-2', name: 'Chidi Eze', phone: '+2348010000002', country: 'NG', status: 'active', trustLevel: 'established', verificationStatus: 'pending', jobsCount: 12, totalSpend: money(1_980_000, 'NGN'), joinedAt: daysAgo(95) },
    { id: 'mu-3', name: 'Wanjiru Kamau', phone: '+254701000003', country: 'KE', status: 'active', trustLevel: 'trusted', verificationStatus: 'verified', jobsCount: 27, totalSpend: money(3_120_000, 'KES'), joinedAt: daysAgo(180) },
    { id: 'mu-4', name: 'Kwame Asante', phone: '+233201000004', country: 'GH', status: 'suspended', trustLevel: 'established', verificationStatus: 'verified', jobsCount: 19, totalSpend: money(940_000, 'GHS'), joinedAt: daysAgo(150), suspension: { reason: 'payment_fraud_review', byAdminId: 'admin-zainab', at: daysAgo(6) } },
    { id: 'mu-5', name: 'Ngozi Bello', phone: '+2348010000005', country: 'NG', status: 'active', trustLevel: 'new', verificationStatus: 'unverified', jobsCount: 1, totalSpend: money(42_000, 'NGN'), joinedAt: daysAgo(9) },
    { id: 'mu-6', name: 'Achieng Odhiambo', phone: '+254701000006', country: 'KE', status: 'active', trustLevel: 'established', verificationStatus: 'verified', jobsCount: 15, totalSpend: money(1_240_000, 'KES'), joinedAt: daysAgo(120) },
    { id: 'mu-7', name: 'Tunde Bakare', phone: '+2348010000007', country: 'NG', status: 'active', trustLevel: 'flagged', verificationStatus: 'verified', jobsCount: 22, totalSpend: money(4_010_000, 'NGN'), joinedAt: daysAgo(160) },
    { id: 'mu-8', name: 'Efua Boateng', phone: '+233201000008', country: 'GH', status: 'active', trustLevel: 'new', verificationStatus: 'pending', jobsCount: 3, totalSpend: money(110_000, 'GHS'), joinedAt: daysAgo(21) },
  ];
  for (const u of users) db.users[u.id] = u;

  const providers: ManagedProvider[] = [
    { id: 'mp-1', name: 'Emeka Obi', phone: '+2348020000001', country: 'NG', status: 'active', trustLevel: 'trusted', verificationStatus: 'verified', rating: 4.8, completedJobs: 212, joinedAt: daysAgo(320) },
    { id: 'mp-2', name: 'Kamau Njoroge', phone: '+254702000002', country: 'KE', status: 'active', trustLevel: 'established', verificationStatus: 'verified', rating: 4.6, completedJobs: 98, joinedAt: daysAgo(200) },
    { id: 'mp-3', name: 'Yaw Darko', phone: '+233202000003', country: 'GH', status: 'active', trustLevel: 'established', verificationStatus: 'pending', rating: 4.2, completedJobs: 41, joinedAt: daysAgo(88) },
    { id: 'mp-4', name: 'Blessing Adeyemi', phone: '+2348020000004', country: 'NG', status: 'suspended', trustLevel: 'established', verificationStatus: 'verified', rating: 4.5, completedJobs: 130, joinedAt: daysAgo(240), suspension: { reason: 'sos_misuse_report', byAdminId: 'admin-amina', at: daysAgo(3) } },
    { id: 'mp-5', name: 'Otieno Ouma', phone: '+254702000005', country: 'KE', status: 'active', trustLevel: 'new', verificationStatus: 'unverified', rating: 0, completedJobs: 0, joinedAt: daysAgo(4) },
    { id: 'mp-6', name: 'Chiamaka Ude', phone: '+234802000006', country: 'NG', status: 'active', trustLevel: 'trusted', verificationStatus: 'verified', rating: 4.9, completedJobs: 305, businessId: 'mb-1', joinedAt: daysAgo(380) },
  ];
  for (const p of providers) db.providers[p.id] = p;

  const businesses: ManagedBusiness[] = [
    { id: 'mb-1', name: 'SwiftErrands Ltd', registrationNumber: 'RC-123456', country: 'NG', status: 'active', verificationStatus: 'verified', providerIds: ['mp-6'], joinedAt: daysAgo(350) },
    { id: 'mb-2', name: 'Nairobi Dashers', registrationNumber: 'KE-2023-8891', country: 'KE', status: 'active', verificationStatus: 'pending', providerIds: [], joinedAt: daysAgo(60) },
    { id: 'mb-3', name: 'Accra Express', registrationNumber: 'GH-44510', country: 'GH', status: 'suspended', verificationStatus: 'verified', providerIds: [], joinedAt: daysAgo(190), suspension: { reason: 'document_expired', byAdminId: 'admin-femi', at: daysAgo(12) } },
  ];
  for (const b of businesses) db.businesses[b.id] = b;

  const workers: ManagedWorker[] = [
    { id: 'mw-1', name: 'Dayo Adeyemi', businessId: 'mb-1', role: 'dispatcher', status: 'active', verificationStatus: 'verified' },
    { id: 'mw-2', name: 'Grace Wambui', businessId: 'mb-2', role: 'courier', status: 'active', verificationStatus: 'pending' },
    { id: 'mw-3', name: 'Kofi Annan', businessId: 'mb-3', role: 'driver', status: 'suspended', verificationStatus: 'verified', suspension: { reason: 'business_suspended', byAdminId: 'admin-femi', at: daysAgo(12) } },
  ];
  for (const w of workers) db.workers[w.id] = w;

  const vehicles: ManagedVehicle[] = [
    { id: 'mv-1', plate: 'LAG-234-XA', make: 'Toyota', model: 'Corolla', ownerProviderId: 'mp-1', status: 'active', verificationStatus: 'verified' },
    { id: 'mv-2', plate: 'NBO-882-B', make: 'Honda', model: 'CB125', ownerProviderId: 'mp-2', status: 'active', verificationStatus: 'verified' },
    { id: 'mv-3', plate: 'ACC-109-C', make: 'Yamaha', model: 'YBR 125', ownerProviderId: 'mp-3', status: 'active', verificationStatus: 'pending' },
    { id: 'mv-4', plate: 'LAG-771-D', make: 'Suzuki', model: 'Every', ownerProviderId: 'mp-6', status: 'active', verificationStatus: 'rejected' },
  ];
  for (const v of vehicles) db.vehicles[v.id] = v;

  // ------------------------------------------------- verification queues
  const queue: VerificationQueueItem[] = [
    { id: 'vq-1', kind: 'id_document', subjectType: 'user', subjectId: 'mu-5', subjectName: 'Ngozi Bello', country: 'NG', submittedAt: hoursAgo(3), status: 'queued', priority: 'high' },
    { id: 'vq-2', kind: 'facial', subjectType: 'provider', subjectId: 'mp-5', subjectName: 'Otieno Ouma', country: 'KE', submittedAt: hoursAgo(7), status: 'queued', priority: 'normal' },
    { id: 'vq-3', kind: 'police_clearance', subjectType: 'provider', subjectId: 'mp-3', subjectName: 'Yaw Darko', country: 'GH', submittedAt: daysAgo(1), status: 'in_review', priority: 'normal', claimedByAdminId: 'admin-femi' },
    { id: 'vq-4', kind: 'vehicle_document', subjectType: 'vehicle', subjectId: 'mv-3', subjectName: 'ACC-109-C (Yamaha YBR 125)', country: 'GH', submittedAt: hoursAgo(20), status: 'queued', priority: 'normal' },
    { id: 'vq-5', kind: 'business_document', subjectType: 'business', subjectId: 'mb-2', subjectName: 'Nairobi Dashers', country: 'KE', submittedAt: daysAgo(2), status: 'in_review', priority: 'high', claimedByAdminId: 'admin-femi' },
    { id: 'vq-6', kind: 'id_document', subjectType: 'user', subjectId: 'mu-2', subjectName: 'Chidi Eze', country: 'NG', submittedAt: daysAgo(4), status: 'approved', priority: 'normal', claimedByAdminId: 'admin-femi', reviewedAt: daysAgo(3) },
    { id: 'vq-7', kind: 'facial', subjectType: 'provider', subjectId: 'mp-2', subjectName: 'Kamau Njoroge', country: 'KE', submittedAt: daysAgo(30), status: 'rejected', priority: 'normal', claimedByAdminId: 'admin-femi', reviewedAt: daysAgo(29), decisionReasonKey: 'verification.face_mismatch' },
  ];
  for (const q of queue) db.verificationQueue[q.id] = q;

  // ----------------------------------------------------------------- jobs
  const lagos = { latitude: 6.4541, longitude: 3.3947 };
  const jobs: JobAdminView[] = [
    {
      id: 'job-1', title: 'Grocery pickup — Shoprite Lekki', categoryId: 'errands', country: 'NG',
      customerId: 'mu-1', customerName: 'Ada Okafor', providerId: 'mp-1', providerName: 'Emeka Obi',
      status: 'in_progress', agreedPrice: money(850_000, 'NGN'), offersCount: 3, createdAt: hoursAgo(5),
      timeline: timeline(hoursAgo(5), [
        ['created', 'customer', 0], ['negotiating', 'system', 1], ['agreed', 'customer', 38],
        ['paid_held', 'system', 41], ['in_progress', 'provider', 75],
      ]),
      routePoints: [
        { latitude: 6.4474, longitude: 3.4723 }, { latitude: 6.4520, longitude: 3.4401 },
        lagos,
      ],
      livePosition: { latitude: 6.4501, longitude: 3.4512 },
    },
    {
      id: 'job-2', title: 'Document delivery to Westlands', categoryId: 'delivery', country: 'KE',
      customerId: 'mu-3', customerName: 'Wanjiru Kamau', providerId: 'mp-2', providerName: 'Kamau Njoroge',
      status: 'paid_held', agreedPrice: money(120_000, 'KES'), offersCount: 2, createdAt: hoursAgo(9),
      timeline: timeline(hoursAgo(9), [
        ['created', 'customer', 0], ['negotiating', 'system', 2], ['agreed', 'customer', 90],
        ['paid_held', 'system', 95],
      ]),
      routePoints: [
        { latitude: -1.2921, longitude: 36.8219 }, { latitude: -1.2635, longitude: 36.8108 },
      ],
    },
    {
      id: 'job-3', title: 'Airport pickup — Kotoka', categoryId: 'transport', country: 'GH',
      customerId: 'mu-8', customerName: 'Efua Boateng', providerId: 'mp-3', providerName: 'Yaw Darko',
      status: 'negotiating', offersCount: 4, createdAt: hoursAgo(2),
      timeline: timeline(hoursAgo(2), [['created', 'customer', 0], ['negotiating', 'system', 1]]),
      routePoints: [
        { latitude: 5.6037, longitude: -0.1870 }, { latitude: 5.6148, longitude: -0.2058 },
      ],
    },
    {
      id: 'job-4', title: 'Pharmacy run', categoryId: 'errands', country: 'NG',
      customerId: 'mu-5', customerName: 'Ngozi Bello', providerId: 'mp-6', providerName: 'Chiamaka Ude',
      status: 'completed_by_provider', agreedPrice: money(420_000, 'NGN'), offersCount: 2, createdAt: daysAgo(1),
      timeline: timeline(daysAgo(1), [
        ['created', 'customer', 0], ['negotiating', 'system', 1], ['agreed', 'customer', 22],
        ['paid_held', 'system', 24], ['in_progress', 'provider', 40],
        ['completed_by_provider', 'provider', 95],
      ]),
      routePoints: [
        { latitude: 6.5244, longitude: 3.3792 }, { latitude: 6.5355, longitude: 3.3678 },
      ],
    },
    {
      id: 'job-5', title: 'Furniture move — Lekki to Yaba', categoryId: 'moving', country: 'NG',
      customerId: 'mu-1', customerName: 'Ada Okafor', providerId: 'mp-6', providerName: 'Chiamaka Ude',
      status: 'disputed', agreedPrice: money(2_500_000, 'NGN'), offersCount: 5, createdAt: daysAgo(2),
      timeline: timeline(daysAgo(2), [
        ['created', 'customer', 0], ['negotiating', 'system', 1], ['agreed', 'customer', 55],
        ['paid_held', 'system', 60], ['in_progress', 'provider', 120],
        ['completed_by_provider', 'provider', 300], ['disputed', 'customer', 420],
      ]),
      routePoints: [
        { latitude: 6.4474, longitude: 3.4723 }, { latitude: 6.4995, longitude: 3.3690 },
      ],
    },
    {
      id: 'job-6', title: 'Cake delivery — Kilimani', categoryId: 'delivery', country: 'KE',
      customerId: 'mu-6', customerName: 'Achieng Odhiambo', providerId: 'mp-2', providerName: 'Kamau Njoroge',
      status: 'confirmed', agreedPrice: money(280_000, 'KES'), offersCount: 3, createdAt: daysAgo(4),
      timeline: timeline(daysAgo(4), [
        ['created', 'customer', 0], ['negotiating', 'system', 1], ['agreed', 'customer', 30],
        ['paid_held', 'system', 33], ['in_progress', 'provider', 50],
        ['completed_by_provider', 'provider', 110], ['confirmed', 'customer', 140],
      ]),
      routePoints: [
        { latitude: -1.3007, longitude: 36.7836 }, { latitude: -1.2921, longitude: 36.7847 },
      ],
    },
    {
      id: 'job-7', title: 'Passport renewal errand', categoryId: 'custom', country: 'GH',
      customerId: 'mu-8', customerName: 'Efua Boateng',
      status: 'payment_pending', agreedPrice: money(180_000, 'GHS'), offersCount: 1, createdAt: minutesAgo(25),
      timeline: timeline(minutesAgo(25), [
        ['created', 'customer', 0], ['negotiating', 'system', 1], ['agreed', 'customer', 18],
        ['payment_pending', 'system', 19],
      ]),
      routePoints: [
        { latitude: 5.5500, longitude: -0.2050 }, { latitude: 5.5600, longitude: -0.1960 },
      ],
    },
    {
      id: 'job-8', title: 'Market run — Balogun', categoryId: 'errands', country: 'NG',
      customerId: 'mu-7', customerName: 'Tunde Bakare', providerId: 'mp-1', providerName: 'Emeka Obi',
      status: 'agreed', agreedPrice: money(1_200_000, 'NGN'), offersCount: 2, createdAt: hoursAgo(14),
      timeline: timeline(hoursAgo(14), [
        ['created', 'customer', 0], ['negotiating', 'system', 2], ['agreed', 'customer', 480],
      ]),
      routePoints: [
        { latitude: 6.4550, longitude: 3.3841 }, { latitude: 6.4698, longitude: 3.3581 },
      ],
    },
  ];
  for (const j of jobs) db.jobs[j.id] = j;

  // ------------------------------------------------------------- payments
  const payments: PaymentAdminView[] = [
    { id: 'pay-hold-1', kind: 'hold', country: 'NG', referenceId: 'job-1', counterpartyName: 'Ada Okafor → Emeka Obi', quote: quote(850_000, 'NGN', 1250), status: 'held', approval: { state: 'none', approverIds: [] }, createdAt: hoursAgo(4) },
    { id: 'pay-hold-2', kind: 'hold', country: 'KE', referenceId: 'job-2', counterpartyName: 'Wanjiru Kamau → Kamau Njoroge', quote: quote(120_000, 'KES', 1200), status: 'held', approval: { state: 'none', approverIds: [] }, createdAt: hoursAgo(7) },
    { id: 'pay-set-1', kind: 'settlement', country: 'KE', referenceId: 'job-6', counterpartyName: 'Kamau Njoroge', quote: quote(280_000, 'KES', 1200), status: 'completed', approval: { state: 'none', approverIds: [] }, createdAt: daysAgo(4) },
    { id: 'pay-pay-1', kind: 'payout', country: 'NG', referenceId: 'mp-6', counterpartyName: 'Chiamaka Ude', quote: { gross: money(1_250_000, 'NGN'), net: money(1_250_000, 'NGN') }, status: 'completed', approval: { state: 'none', approverIds: [] }, createdAt: daysAgo(3) },
    { id: 'pay-pay-2', kind: 'payout', country: 'KE', referenceId: 'mp-2', counterpartyName: 'Kamau Njoroge', quote: { gross: money(96_400, 'KES'), net: money(96_400, 'KES') }, status: 'processing', approval: { state: 'none', approverIds: [] }, createdAt: hoursAgo(18) },
    {
      id: 'pay-wd-1', kind: 'withdrawal', country: 'NG', referenceId: 'mp-1', counterpartyName: 'Emeka Obi',
      quote: { gross: money(3_000_000, 'NGN'), net: money(3_000_000, 'NGN') }, status: 'pending',
      approval: { state: 'awaiting_second', approverIds: ['admin-zainab'], requestedAt: hoursAgo(2) },
      createdAt: hoursAgo(6),
    },
    {
      id: 'pay-wd-2', kind: 'withdrawal', country: 'GH', referenceId: 'mp-3', counterpartyName: 'Yaw Darko',
      quote: { gross: money(450_000, 'GHS'), net: money(450_000, 'GHS') }, status: 'pending',
      approval: { state: 'single_pending', approverIds: [], requestedAt: hoursAgo(10) },
      createdAt: hoursAgo(12),
    },
    {
      id: 'pay-wd-3', kind: 'withdrawal', country: 'NG', referenceId: 'mp-6', counterpartyName: 'Chiamaka Ude',
      quote: { gross: money(800_000, 'NGN'), net: money(800_000, 'NGN') }, status: 'completed',
      approval: { state: 'approved', approverIds: ['admin-zainab', 'admin-amina'], requestedAt: daysAgo(5), decidedAt: daysAgo(5) },
      createdAt: daysAgo(5),
    },
    {
      // Above the NGN two-person threshold but still single_pending —
      // approveWithdrawal refuses it with ERR_APPROVAL_REQUIRED so the UI
      // exercises the requestApproval → confirmApproval flow from scratch.
      id: 'pay-wd-4', kind: 'withdrawal', country: 'NG', referenceId: 'mb-1', counterpartyName: 'SwiftErrands Ltd',
      quote: { gross: money(4_500_000, 'NGN'), net: money(4_500_000, 'NGN') }, status: 'pending',
      approval: { state: 'single_pending', approverIds: [], requestedAt: hoursAgo(1) },
      createdAt: hoursAgo(2),
    },
  ];
  for (const p of payments) db.payments[p.id] = p;

  // ------------------------------------------------------------ referrals
  const attributions: ReferralAttribution[] = [
    { id: 'ra-1', referrerId: 'mu-1', referrerName: 'Ada Okafor', refereeId: 'mu-5', refereeName: 'Ngozi Bello', country: 'NG', attributedAt: daysAgo(9), qualifyingJobs: 3, commissionEarned: money(45_000, 'NGN') },
    { id: 'ra-2', referrerId: 'mu-3', referrerName: 'Wanjiru Kamau', refereeId: 'mu-6', refereeName: 'Achieng Odhiambo', country: 'KE', attributedAt: daysAgo(60), qualifyingJobs: 2, commissionEarned: money(30_000, 'KES') },
    { id: 'ra-3', referrerId: 'mu-2', referrerName: 'Chidi Eze', refereeId: 'mu-7', refereeName: 'Tunde Bakare', country: 'NG', attributedAt: daysAgo(20), qualifyingJobs: 5, commissionEarned: money(120_000, 'NGN') },
    { id: 'ra-4', referrerId: 'mu-8', referrerName: 'Efua Boateng', refereeId: 'mu-4', refereeName: 'Kwame Asante', country: 'GH', attributedAt: daysAgo(14), qualifyingJobs: 1, commissionEarned: money(15_000, 'GHS') },
  ];
  for (const a of attributions) db.referralAttributions[a.id] = a;

  const flags: ReferralFlaggedCase[] = [
    { id: 'rf-1', attributionId: 'ra-3', reason: 'device_cluster', signals: ['shared device hash across referrer/referee', 'same /24 IP block', '5 attributions in 48h'], flaggedAt: daysAgo(18), status: 'open' },
    { id: 'rf-2', attributionId: 'ra-4', reason: 'self_referral_suspected', signals: ['same payment card on both accounts'], flaggedAt: daysAgo(13), status: 'open' },
  ];
  for (const f of flags) db.referralFlags[f.id] = f;

  const campaigns: ReferralCampaign[] = [
    { id: 'rc-1', name: 'Lagos Launch Boost', country: 'NG', referrerReward: money(100_000, 'NGN'), refereeReward: money(50_000, 'NGN'), status: 'active', startsAt: daysAgo(30) },
    { id: 'rc-2', name: 'Nairobi Refer-a-Friend', country: 'KE', referrerReward: money(50_000, 'KES'), refereeReward: money(25_000, 'KES'), status: 'paused', startsAt: daysAgo(90), endsAt: daysAgo(10) },
  ];
  for (const c of campaigns) db.referralCampaigns[c.id] = c;

  // --------------------------------------------------------------- promos
  const promos: PromoCampaign[] = [
    { id: 'promo-1', code: 'WELCOME10', country: 'NG', discountPercent: 10, maxDiscount: money(100_000, 'NGN'), budget: money(5_000_000, 'NGN'), spent: money(1_200_000, 'NGN'), maxRedemptions: 1000, redemptions: 214, status: 'active', startsAt: daysAgo(45), endsAt: new Date(Date.now() + 45 * 86_400_000) },
    { id: 'promo-2', code: 'FESTIVE20', country: 'NG', discountPercent: 20, maxDiscount: money(200_000, 'NGN'), budget: money(8_000_000, 'NGN'), spent: money(8_000_000, 'NGN'), maxRedemptions: 500, redemptions: 500, status: 'expired', startsAt: daysAgo(120), endsAt: daysAgo(60) },
    { id: 'promo-3', code: 'RIDEGH15', country: 'GH', discountPercent: 15, maxDiscount: money(60_000, 'GHS'), budget: money(1_500_000, 'GHS'), spent: money(0, 'GHS'), maxRedemptions: 300, redemptions: 0, status: 'draft', startsAt: new Date(Date.now() + 7 * 86_400_000), endsAt: new Date(Date.now() + 37 * 86_400_000) },
  ];
  for (const p of promos) db.promos[p.id] = p;

  // ------------------------------------------------------------- disputes
  const disputes: DisputeCase[] = [
    {
      id: 'disp-1', jobId: 'job-5', country: 'NG', customerId: 'mu-1', customerName: 'Ada Okafor',
      providerId: 'mp-6', providerName: 'Chiamaka Ude', reasonKey: 'dispute.item_damaged',
      status: 'in_review', openedAt: daysAgo(2), assignedToAdminId: 'admin-sola',
      heldAmount: money(2_500_000, 'NGN'),
      evidence: [
        { id: 'ev-1', kind: 'photo', label: 'Scratched table top', uploadedBy: 'customer', uploadedAt: daysAgo(2) },
        { id: 'ev-2', kind: 'photo', label: 'Item condition at pickup', uploadedBy: 'provider', uploadedAt: daysAgo(2) },
        { id: 'ev-3', kind: 'chat_excerpt', label: 'Chat thread around delivery', uploadedBy: 'system', uploadedAt: daysAgo(2) },
      ],
    },
    {
      id: 'disp-2', jobId: 'job-4', country: 'NG', customerId: 'mu-5', customerName: 'Ngozi Bello',
      providerId: 'mp-6', providerName: 'Chiamaka Ude', reasonKey: 'dispute.not_as_described',
      status: 'open', openedAt: hoursAgo(20),
      heldAmount: money(420_000, 'NGN'),
      evidence: [
        { id: 'ev-4', kind: 'location_log', label: 'Route deviation detected', uploadedBy: 'system', uploadedAt: hoursAgo(20) },
      ],
    },
  ];
  for (const d of disputes) db.disputes[d.id] = d;

  // -------------------------------------------------------------- support
  const tickets: SupportTicketAdmin[] = [
    {
      id: 'st-1', userId: 'mu-2', userName: 'Chidi Eze', country: 'NG', subject: 'Payment debited twice',
      status: 'open', priority: 'high', createdAt: hoursAgo(6),
      messages: [
        { id: 'stm-1', author: 'customer', body: 'My card was charged twice for job-8.', at: hoursAgo(6) },
        { id: 'stm-2', author: 'ai', body: 'Triage: possible duplicate gateway capture; recommend finance review.', at: hoursAgo(6) },
      ],
    },
    {
      id: 'st-2', userId: 'mu-3', userName: 'Wanjiru Kamau', country: 'KE', subject: 'How do I become a provider?',
      status: 'assigned', priority: 'normal', assignedToAdminId: 'admin-kojo', createdAt: daysAgo(1),
      messages: [
        { id: 'stm-3', author: 'customer', body: 'I want to offer delivery services.', at: daysAgo(1) },
        { id: 'stm-4', author: 'agent', body: 'Sharing the provider onboarding steps now.', at: hoursAgo(22) },
      ],
    },
    {
      id: 'st-3', userId: 'mu-6', userName: 'Achieng Odhiambo', country: 'KE', subject: 'App crashes on chat',
      status: 'closed', priority: 'normal', assignedToAdminId: 'admin-kojo', createdAt: daysAgo(5),
      messages: [
        { id: 'stm-5', author: 'customer', body: 'Chat screen freezes on Android 12.', at: daysAgo(5) },
        { id: 'stm-6', author: 'agent', body: 'Fixed in the latest build — please update.', at: daysAgo(4) },
      ],
    },
  ];
  for (const t of tickets) db.tickets[t.id] = t;

  // ------------------------------------------------------------------ sos
  const sos: SosAlertAdmin[] = [
    {
      id: 'sos-1', jobId: 'job-1', country: 'NG', triggeredBy: 'customer', userName: 'Ada Okafor',
      userPhone: '+2348010000001', status: 'active', triggeredAt: minutesAgo(12),
      trail: [
        { at: minutesAgo(12), point: { latitude: 6.4474, longitude: 3.4723 } },
        { at: minutesAgo(8), point: { latitude: 6.4489, longitude: 3.4650 } },
        { at: minutesAgo(4), point: { latitude: 6.4501, longitude: 3.4512 } },
      ],
    },
    {
      id: 'sos-2', jobId: 'job-4', country: 'NG', triggeredBy: 'provider', userName: 'Chiamaka Ude',
      userPhone: '+2348020000006', status: 'acknowledged', triggeredAt: daysAgo(1),
      acknowledgedByAdminId: 'admin-amina', acknowledgedAt: daysAgo(1),
      trail: [
        { at: daysAgo(1), point: { latitude: 6.5244, longitude: 3.3792 } },
        { at: daysAgo(1), point: { latitude: 6.5301, longitude: 3.3740 } },
      ],
    },
  ];
  for (const s of sos) db.sosAlerts[s.id] = s;

  // ----------------------------------------------------------------- risk
  const risk: RiskCase[] = [
    { id: 'rk-1', kind: 'payment_fraud', country: 'NG', subjectUserId: 'mu-7', subjectName: 'Tunde Bakare', signals: ['3 chargebacks in 30 days', 'card testing pattern at checkout'], status: 'open', openedAt: daysAgo(2) },
    { id: 'rk-2', kind: 'collusion', country: 'KE', subjectUserId: 'mp-2', subjectName: 'Kamau Njoroge', signals: ['repeat counterparty concentration > 60%', 'mutual 5-star rating loop'], status: 'reviewed', openedAt: daysAgo(15), reviewedByAdminId: 'admin-amina' },
    { id: 'rk-3', kind: 'account_takeover', country: 'GH', subjectUserId: 'mu-4', subjectName: 'Kwame Asante', signals: ['login from new device + country', 'password reset then withdrawal attempt'], status: 'escalated', openedAt: daysAgo(7), reviewedByAdminId: 'admin-zainab' },
  ];
  for (const r of risk) db.riskCases[r.id] = r;

  // --------------------------------------------------------------- config
  const flags2: FeatureFlag[] = [
    { key: 'concierge_voice', description: 'Voice concierge (English only until Pidgin gate)', enabled: false, countries: [] },
    { key: 'wallet_passes', description: 'Apple/Google wallet passes', enabled: true, countries: ['NG', 'KE'] },
    { key: 'sos_auto_escalation', description: 'Auto-escalate unacknowledged SOS after 5 min', enabled: true, countries: [] },
    { key: 'ai_admin_assistant', description: 'AI Admin Assistant in the console', enabled: true, countries: [] },
    { key: 'referral_boosts', description: 'Referral boost campaigns', enabled: false, countries: ['GH'] },
  ];
  for (const f of flags2) db.featureFlags[f.key] = f;

  db.countryPackConfigs = {
    NG: { country: 'NG', currency: 'NGN', live: true, categories: ['errands', 'delivery', 'moving', 'transport', 'custom'], supportPhone: '+2347000000000' },
    KE: { country: 'KE', currency: 'KES', live: true, categories: ['errands', 'delivery', 'custom'], supportPhone: '+254700000000' },
    GH: { country: 'GH', currency: 'GHS', live: false, categories: ['errands', 'delivery'], supportPhone: '+233700000000' },
  };

  db.commissionConfigs = {
    NG: { country: 'NG', rateBps: 1250, effectiveFrom: daysAgo(90) },
    KE: { country: 'KE', rateBps: 1200, effectiveFrom: daysAgo(90) },
    GH: { country: 'GH', rateBps: 1300, effectiveFrom: daysAgo(60) },
  };

  const changes: ConfigChange[] = [
    {
      id: 'cc-1', target: 'commission', targetKey: 'GH', summary: 'GH commission 1300 → 1100 bps',
      proposedValue: { rateBps: 1100 }, proposedByAdminId: 'admin-zainab', proposedAt: hoursAgo(8),
      status: 'proposed',
    },
    {
      id: 'cc-2', target: 'feature_flag', targetKey: 'referral_boosts', summary: 'Enable referral_boosts in GH',
      proposedValue: { enabled: true }, proposedByAdminId: 'admin-amina', proposedAt: daysAgo(6),
      status: 'approved', decidedByAdminId: 'admin-zainab', decidedAt: daysAgo(5),
    },
  ];
  for (const c of changes) db.configChanges[c.id] = c;

  // ------------------------------------------------------------ analytics
  const metricsToSeed: Array<[AnalyticsMetric, number]> = [
    ['gmv', 1_000_000],
    ['jobs_completed', 320],
    ['dau', 5000],
    ['dispute_rate', 3],
    ['offer_acceptance_rate', 62],
  ];
  for (const country of ['NG', 'KE', 'GH']) {
    const currency = db.metrics[country].currency;
    const scale = country === 'NG' ? 1 : country === 'KE' ? 0.4 : 0.25;
    for (const [metric, base] of metricsToSeed) {
      const points = Array.from({ length: 30 }, (_, i) => {
        const jitter = 0.8 + 0.4 * seededValue(`${country}:${metric}`, i);
        const trend = 1 + i * 0.005;
        return {
          date: daysAgo(29 - i).toISOString().slice(0, 10),
          value: Math.round(base * scale * jitter * trend * 100) / 100,
        };
      });
      db.analytics.push({ metric, country, currency, points });
    }
  }

  // ---------------------------------------------------------- audit seeds
  const seedAudit: Array<[string, string, string, string | undefined, Date]> = [
    ['admin-zainab', 'directory.suspend', 'user/mu-4', 'payment_fraud_review', daysAgo(6)],
    ['admin-femi', 'verification.approve', 'verification/vq-6', undefined, daysAgo(3)],
    ['admin-amina', 'sos.acknowledge', 'sos/sos-2', undefined, daysAgo(1)],
    ['admin-amina', 'config.propose', 'feature_flag/referral_boosts', 'Enable referral_boosts in GH', daysAgo(6)],
    ['admin-zainab', 'payments.approve_withdrawal', 'payment/pay-wd-1', 'first approval', hoursAgo(2)],
  ];
  for (const [adminId, action, target, reason, at] of seedAudit) {
    db.appendAudit(db.adminUsers[adminId], action, target, reason, at);
  }

  // -------------------------------------------------------------- ai chat
  db.aiChat.push({
    id: 'ai-seed-1',
    role: 'assistant',
    body: 'Console assistant ready. I can summarize metrics, surface anomalies, and point you at the right module — I never change data myself.',
    at: new Date(),
  });

  return db;
}

/** Shared seeded instance used by the repository singletons. */
export const db = createMockDatabase();
