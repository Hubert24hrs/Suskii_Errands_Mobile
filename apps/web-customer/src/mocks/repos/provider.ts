// Provider-mode mock repositories, mirroring the Dart mock layer
// (packages/suskii_data/lib/src/mock/mock_repositories.dart): the feed, the
// provider's offers and jobs, job execution, KYC, provider tools and the
// business console. The server decides; these simulate its answers.

import { simulateQuote } from '../behavior';
import { AppError, ErrorCodes } from '../errors';
import type { MockBehavior } from '../behavior';
import type { MockDatabase } from '../fixtures';
import {
  isTerminalJobStatus,
  type AvailabilitySlot,
  type BusinessRole,
  type DemandZone,
  type EarningsGoal,
  type GeoPoint,
  type GoalPeriod,
  type HandoverPinKind,
  type InstantPayoutQuote,
  type JobRequest,
  type JobStatus,
  type KycStepInput,
  type KycStepKind,
  type Money,
  type Offer,
  type OrgInvitation,
  type OrgMember,
  type Organization,
  type PayoutAccountResult,
  type PinVerificationResult,
  type Proof,
  type ProofKind,
  type ProviderHomeSummary,
  type ProviderInsights,
  type ProviderKycProfile,
  type ProviderOnboardingInput,
  type UploadBucket,
  type Vehicle,
  type WalletTransaction,
} from '../types';
import { MockRepo, type Unsubscribe } from './base';

/** Open for offers: what the provider feed lists. */
const OPEN_FOR_OFFERS: ReadonlySet<JobStatus> = new Set([
  'published',
  'offers_received',
  'negotiating',
]);

/** The mock's known handover PIN, the same one the customer side reveals. */
const MOCK_PIN = '428135';

let idCounter = 0;
function mockId(prefix: string): string {
  idCounter += 1;
  return `${prefix}-${Date.now().toString(36)}-${idCounter}`;
}

export class MockProviderRepository extends MockRepo {
  constructor(db: MockDatabase, behavior: MockBehavior) {
    super(db, behavior);
  }

  /** The real feed is country-scoped server-side; never the caller's own requests. */
  private inFeed(request: JobRequest): boolean {
    const me = this.currentUser;
    return (
      OPEN_FOR_OFFERS.has(request.status) &&
      request.customerId !== me.id &&
      this.db.users[request.customerId]?.countryCode === me.countryCode
    );
  }

  async getHomeSummary(): Promise<ProviderHomeSummary> {
    await this.gate();
    const me = this.currentUser;
    const profile = this.db.providers[me.id];
    return {
      online: profile?.online ?? false,
      verificationStatus: me.providerVerification,
      todayEarnings: { amountMinor: 1260000, currency: 'NGN' },
      completedToday: 3,
      nearbyOpenRequests: Object.values(this.db.requests).filter((r) => this.inFeed(r)).length,
      documentWarnings: [{ documentTypeKey: 'docPoliceClearance', daysRemaining: 14 }],
    };
  }

  watchNearbyRequests(onChange: (requests: JobRequest[]) => void): Unsubscribe {
    const emit = () =>
      onChange(
        Object.values(this.db.requests)
          .filter((r) => this.inFeed(r))
          .sort((a, b) => b.createdAt.getTime() - a.createdAt.getTime()),
      );
    emit();
    return this.db.jobEvents.subscribe(emit);
  }

  async getMyOffers(): Promise<Offer[]> {
    await this.gate();
    const me = this.currentUser.id;
    return Object.values(this.db.offers)
      .flat()
      .filter((o) => o.providerId === me)
      .sort((a, b) => b.createdAt.getTime() - a.createdAt.getTime());
  }

  private myActiveJobs(): JobRequest[] {
    const me = this.currentUser.id;
    return Object.values(this.db.requests)
      .filter((r) => r.providerId === me && !isTerminalJobStatus(r.status))
      .sort((a, b) => b.createdAt.getTime() - a.createdAt.getTime());
  }

  watchMyJobs(onChange: (jobs: JobRequest[]) => void): Unsubscribe {
    const emit = () => onChange(this.myActiveJobs());
    emit();
    return this.db.jobEvents.subscribe(emit);
  }

  async getMyJobsHistory(): Promise<JobRequest[]> {
    await this.gate();
    const me = this.currentUser.id;
    return Object.values(this.db.requests)
      .filter((r) => r.providerId === me && isTerminalJobStatus(r.status))
      .sort((a, b) => b.createdAt.getTime() - a.createdAt.getTime());
  }

  async submitOffer(options: {
    requestId: string;
    amount: Money;
    idempotencyKey: string;
    message?: string;
  }): Promise<Offer> {
    await this.gate();
    const { requestId, amount, idempotencyKey, message } = options;
    return this.idempotent(
      `submitOffer:${requestId}`,
      idempotencyKey,
      `${amount.amountMinor} ${amount.currency}|${message ?? ''}`,
      () => {
        const me = this.currentUser;
        if (me.providerVerification !== 'verified') {
          throw new AppError(ErrorCodes.providerNotVerified);
        }
        const request = this.db.requests[requestId];
        if (!request || !OPEN_FOR_OFFERS.has(request.status)) {
          throw new AppError(ErrorCodes.requestNotFound);
        }
        if (request.customerId === me.id) throw new AppError(ErrorCodes.selfDealingBlocked);
        if (!Number.isSafeInteger(amount.amountMinor) || amount.amountMinor <= 0) {
          throw new AppError(ErrorCodes.priceOutOfRange);
        }
        const list = (this.db.offers[requestId] ??= []);
        if (list.some((o) => o.providerId === me.id && (o.status === 'pending' || o.status === 'countered'))) {
          throw new AppError(ErrorCodes.offerAlreadyPending);
        }
        const profile = this.db.providers[me.id];
        const offer: Offer = {
          id: mockId('offer'),
          requestId,
          providerId: me.id,
          providerName: me.displayName,
          providerRating: profile?.rating ?? 0,
          providerTrustLevel: me.trustLevel,
          amount,
          status: 'pending',
          round: 1,
          createdAt: this.now(),
          message,
          payoutEstimate: simulateQuote(amount),
          expiresAt: new Date(this.now().getTime() + 10 * 60_000),
        };
        list.push(offer);
        if (request.status === 'published') {
          const updated: JobRequest = { ...request, status: 'offers_received' };
          this.db.requests[requestId] = updated;
          this.db.jobEvents.emit(updated);
        }
        this.db.offerEvents.emit(offer);
        return offer;
      },
    );
  }

  /** The heartbeat between jobs; the mock keeps nothing. */
  async reportPosition(_point: GeoPoint, _accuracyMetres?: number): Promise<void> {}

  /** set_online takes no idempotency key server-side: the toggle replays as itself. */
  async setOnline(online: boolean, _idempotencyKey: string): Promise<boolean> {
    await this.gate();
    const me = this.currentUser;
    if (online && me.providerVerification === 'expired') throw new AppError(ErrorCodes.kycExpired);
    if (online && me.providerVerification !== 'verified') {
      throw new AppError(ErrorCodes.providerNotVerified);
    }
    const profile = this.db.providers[me.id];
    if (profile) this.db.providers[me.id] = { ...profile, online };
    return online;
  }
}

/**
 * The provider's side of job execution: the state machine runs here the way
 * `set_job_status`, `verify_pin` and `submit_proof` run it server-side.
 */
export class MockProviderJobRepository extends MockRepo {
  constructor(db: MockDatabase, behavior: MockBehavior) {
    super(db, behavior);
  }

  private pinAttempts: Record<string, number> = {};
  private deliveryPinVerified: Record<string, boolean> = {};

  private myJob(jobId: string): JobRequest {
    const job = this.db.requests[jobId];
    if (!job) throw new AppError(ErrorCodes.requestNotFound);
    if (job.providerId !== this.currentUser.id) throw new AppError(ErrorCodes.permissionDenied);
    return job;
  }

  private save(job: JobRequest): JobRequest {
    this.db.requests[job.id] = job;
    this.db.jobEvents.emit(job);
    return job;
  }

  async requestStatusChange(
    jobId: string,
    target: JobStatus,
    options: { idempotencyKey: string; location?: GeoPoint; reasonCode?: string },
  ): Promise<JobRequest> {
    await this.gate();
    return this.idempotent(
      `setJobStatus:${jobId}`,
      options.idempotencyKey,
      `${target}|${options.reasonCode ?? ''}`,
      () => {
        const job = this.myJob(jobId);
        const allowed: Partial<Record<JobStatus, JobStatus>> = {
          paid_held: 'en_route',
          assigned: 'en_route',
          en_route: 'arrived',
          in_progress: 'completed_by_provider',
        };
        if (allowed[job.status] !== target) throw new AppError(ErrorCodes.illegalTransition);
        if (target === 'arrived' && !options.location && !options.reasonCode) {
          throw new AppError(ErrorCodes.notAtPickup);
        }
        if (target === 'completed_by_provider') {
          const category = this.db.categories.find((c) => c.id === job.categoryId);
          const proofs = this.db.proofs[jobId] ?? [];
          const missing = Object.entries(category?.proofRequirements ?? {}).some(
            ([kind, count]) => proofs.filter((p) => p.kind === kind).length < count,
          );
          if (missing) throw new AppError(ErrorCodes.proofRequired);
          if (job.destination && !this.deliveryPinVerified[jobId]) {
            throw new AppError(ErrorCodes.proofRequired);
          }
        }
        return this.save({ ...job, status: target });
      },
    );
  }

  /** A wrong PIN returns a result; only the exhausted case raises. */
  async verifyHandoverPin(
    jobId: string,
    pin: string,
    kind: HandoverPinKind,
    idempotencyKey: string,
  ): Promise<PinVerificationResult> {
    await this.gate();
    return this.idempotent(`verifyPin:${jobId}:${kind}`, idempotencyKey, pin, () => {
      const job = this.myJob(jobId);
      if (kind === 'pickup' && job.status !== 'arrived') throw new AppError(ErrorCodes.illegalTransition);
      if (kind === 'delivery' && job.status !== 'in_progress') {
        throw new AppError(ErrorCodes.illegalTransition);
      }
      const key = `${jobId}:${kind}`;
      const used = this.pinAttempts[key] ?? 0;
      if (used >= 5) throw new AppError(ErrorCodes.pinAttemptsExceeded);
      if (pin !== MOCK_PIN) {
        this.pinAttempts[key] = used + 1;
        return { verified: false, status: job.status, attemptsRemaining: 5 - used - 1 };
      }
      if (kind === 'pickup') {
        const updated = this.save({ ...job, status: 'in_progress' });
        return { verified: true, status: updated.status, attemptsRemaining: 5 - used };
      }
      this.deliveryPinVerified[jobId] = true;
      return { verified: true, status: job.status, attemptsRemaining: 5 - used };
    });
  }

  async submitProof(options: {
    jobId: string;
    kind: ProofKind;
    storagePath: string;
    idempotencyKey: string;
    capturedAt?: Date;
  }): Promise<Proof> {
    await this.gate();
    const { jobId, kind, storagePath, idempotencyKey, capturedAt } = options;
    return this.idempotent(`submitProof:${jobId}`, idempotencyKey, `${kind}|${storagePath}`, () => {
      const job = this.myJob(jobId);
      if (job.status !== 'in_progress' && job.status !== 'completed_by_provider') {
        throw new AppError(ErrorCodes.illegalTransition);
      }
      if (!storagePath.startsWith(`${jobId}/`)) throw new AppError(ErrorCodes.permissionDenied);
      const proof: Proof = {
        id: mockId('proof'),
        jobId,
        providerId: this.currentUser.id,
        kind,
        storagePath,
        createdAt: this.now(),
        capturedAt,
      };
      (this.db.proofs[jobId] ??= []).push(proof);
      return proof;
    });
  }

  async getProofs(jobId: string): Promise<Proof[]> {
    await this.gate();
    const job = this.db.requests[jobId];
    const me = this.currentUser.id;
    if (!job || (job.providerId !== me && job.customerId !== me)) {
      throw new AppError(ErrorCodes.requestNotFound);
    }
    return [...(this.db.proofs[jobId] ?? [])];
  }

  /** The provider's live position for the customer's map: dropped by the mock. */
  async publishProviderLocation(_jobId: string, _point: GeoPoint): Promise<void> {}
}

/** Uploads land nowhere in the mock; the path is built the way the bucket policies read it. */
export class MockMediaUploadRepository extends MockRepo {
  constructor(db: MockDatabase, behavior: MockBehavior) {
    super(db, behavior);
  }

  async upload(options: { bucket: UploadBucket; file: Blob; requestId?: string }): Promise<string> {
    await this.gate();
    if (options.file.size === 0) throw new AppError(ErrorCodes.invalidArgument);
    const jobScoped = options.bucket === 'job-proofs' || options.bucket === 'receipts';
    if (jobScoped && !options.requestId) throw new AppError(ErrorCodes.invalidArgument);
    const folder = jobScoped ? options.requestId! : this.currentUser.id;
    return `${folder}/${mockId('file')}`;
  }
}

const REQUIRED_STEPS: readonly KycStepKind[] = [
  'government_id',
  'provider_facial',
  'id_document_capture',
  'police_clearance',
  'address',
  'guarantor',
  'payout_account',
];

const MOTORIZED = new Set(['motorcycle', 'tricycle', 'car', 'van', 'truck']);

export class MockProviderKycRepository extends MockRepo {
  constructor(db: MockDatabase, behavior: MockBehavior) {
    super(db, behavior);
  }

  private profile(): ProviderKycProfile {
    const me = this.currentUser.id;
    const existing = this.db.kycProfiles[me];
    if (existing) return existing;
    const created: ProviderKycProfile = {
      userId: me,
      kind: 'individual',
      serviceCategoryIds: [],
      serviceAreaIds: [],
      overallStatus: 'not_started',
      steps: [...REQUIRED_STEPS, 'vehicle_documents', 'credentials'].map((kind) => ({
        kind: kind as KycStepKind,
        status: 'not_started',
        attemptCount: 0,
      })),
    };
    this.db.kycProfiles[me] = created;
    return created;
  }

  async getKycProfile(): Promise<ProviderKycProfile> {
    await this.gate();
    return this.profile();
  }

  async saveOnboarding(input: ProviderOnboardingInput, idempotencyKey: string): Promise<ProviderKycProfile> {
    await this.gate();
    return this.idempotent('saveOnboarding', idempotencyKey, JSON.stringify(input), () => {
      if (input.serviceCategoryIds.length === 0) throw new AppError(ErrorCodes.invalidArgument);
      const codes = new Set(
        (this.db.countryPacks[this.currentUser.countryCode]?.serviceAreas ?? []).map((a) => a.code),
      );
      if (input.serviceAreaIds.some((code) => !codes.has(code))) {
        throw new AppError(ErrorCodes.cityNotFound);
      }
      const updated: ProviderKycProfile = {
        ...this.profile(),
        serviceCategoryIds: [...input.serviceCategoryIds],
        serviceAreaIds: [...input.serviceAreaIds],
        vehicleType: input.vehicleType,
      };
      this.db.kycProfiles[updated.userId] = updated;
      return updated;
    });
  }

  async submitStep(input: KycStepInput, idempotencyKey: string): Promise<ProviderKycProfile> {
    await this.gate();
    return this.idempotent(`submitKycStep:${input.kind}`, idempotencyKey, JSON.stringify(input), () => {
      if (input.kind === 'provider_facial' && this.behavior.failLiveness) {
        throw new AppError(ErrorCodes.verificationFailed);
      }
      const profile = this.profile();
      const steps = profile.steps.map((s) =>
        s.kind === input.kind
          ? { ...s, status: 'in_review' as const, attemptCount: s.attemptCount + 1, submittedAt: this.now() }
          : s,
      );
      const updated: ProviderKycProfile = {
        ...profile,
        steps,
        overallStatus: profile.overallStatus === 'not_started' ? 'in_progress' : profile.overallStatus,
      };
      this.db.kycProfiles[updated.userId] = updated;
      return updated;
    });
  }

  /** The name lookup is the gateway's, server-side; the mock answers with the verified name. */
  async resolvePayoutAccount(input: { bankCode: string; accountNumber: string }): Promise<PayoutAccountResult> {
    await this.gate();
    if (!/^\d{10}$/.test(input.accountNumber)) throw new AppError(ErrorCodes.invalidArgument);
    return {
      bankCode: input.bankCode,
      maskedAccountNumber: `••••••${input.accountNumber.slice(-4)}`,
      resolvedName: this.currentUser.displayName.toUpperCase(),
      nameMatch: true,
    };
  }

  async submitForReview(idempotencyKey: string): Promise<ProviderKycProfile> {
    await this.gate();
    return this.idempotent('submitKycForReview', idempotencyKey, '', () => {
      const profile = this.profile();
      const required = [...REQUIRED_STEPS];
      if (profile.vehicleType && MOTORIZED.has(profile.vehicleType)) required.push('vehicle_documents');
      const done = (kind: KycStepKind) =>
        profile.steps.some((s) => s.kind === kind && (s.status === 'in_review' || s.status === 'verified'));
      if (!required.every(done)) throw new AppError(ErrorCodes.kycIncomplete);
      const updated: ProviderKycProfile = {
        ...profile,
        overallStatus: profile.overallStatus === 'verified' ? 'verified' : 'in_review',
        submittedForReviewAt: this.now(),
      };
      this.db.kycProfiles[updated.userId] = updated;
      return updated;
    });
  }
}

export class MockProviderToolsRepository extends MockRepo {
  constructor(db: MockDatabase, behavior: MockBehavior) {
    super(db, behavior);
  }

  async getAvailability(): Promise<AvailabilitySlot[]> {
    await this.gate();
    return [...(this.db.availability[this.currentUser.id] ?? [])];
  }

  async setAvailability(slots: AvailabilitySlot[], idempotencyKey: string): Promise<AvailabilitySlot[]> {
    await this.gate();
    return this.idempotent('setAvailability', idempotencyKey, JSON.stringify(slots), () => {
      for (const slot of slots) {
        const valid =
          slot.dayOfWeek >= 1 &&
          slot.dayOfWeek <= 7 &&
          slot.startMinutes >= 0 &&
          slot.endMinutes <= 1440 &&
          slot.startMinutes < slot.endMinutes;
        if (!valid) throw new AppError(ErrorCodes.invalidArgument);
      }
      const sorted = [...slots].sort((a, b) => a.dayOfWeek - b.dayOfWeek || a.startMinutes - b.startMinutes);
      this.db.availability[this.currentUser.id] = sorted;
      return sorted;
    });
  }

  async getEarningsGoal(): Promise<EarningsGoal | undefined> {
    await this.gate();
    return this.db.earningsGoals[this.currentUser.id];
  }

  async setEarningsGoal(target: Money, period: GoalPeriod, idempotencyKey: string): Promise<EarningsGoal> {
    await this.gate();
    return this.idempotent('setEarningsGoal', idempotencyKey, `${target.amountMinor}|${period}`, () => {
      if (!Number.isSafeInteger(target.amountMinor) || target.amountMinor <= 0) {
        throw new AppError(ErrorCodes.invalidArgument);
      }
      const previous = this.db.earningsGoals[this.currentUser.id];
      const goal: EarningsGoal = {
        target,
        period,
        progress: previous?.progress ?? { amountMinor: 0, currency: target.currency },
      };
      this.db.earningsGoals[this.currentUser.id] = goal;
      return goal;
    });
  }

  /** Coarse cells with open requests, never a pickup (the k-anonymity floor applies server-side). */
  async getDemandHeatmap(): Promise<DemandZone[]> {
    await this.gate();
    return [
      { id: 'cell-lekki', label: 'Lekki Phase 1', center: { latitude: 6.448, longitude: 3.472 }, intensity: 0.9, openRequests: 14 },
      { id: 'cell-yaba', label: 'Yaba', center: { latitude: 6.509, longitude: 3.371 }, intensity: 0.6, openRequests: 9 },
      { id: 'cell-ikeja', label: 'Ikeja', center: { latitude: 6.6, longitude: 3.35 }, intensity: 0.4, openRequests: 6 },
    ];
  }

  async getInsights(): Promise<ProviderInsights> {
    await this.gate();
    return {
      acceptanceRate: 0.82,
      completionRate: 0.97,
      avgRating: 4.8,
      fiveStarShare: 0.86,
      avgResponseTimeSeconds: 80,
      periodDays: 30,
    };
  }

  /** Instant payout needs a payment gateway (client action 4): the same answer the real backend gives. */
  async quoteInstantPayout(_amount: Money): Promise<InstantPayoutQuote> {
    await this.gate();
    throw new AppError(ErrorCodes.featureUnavailable);
  }

  async requestInstantPayout(_amount: Money, _idempotencyKey: string): Promise<WalletTransaction> {
    await this.gate();
    throw new AppError(ErrorCodes.featureUnavailable);
  }
}

export class MockOrganizationRepository extends MockRepo {
  constructor(db: MockDatabase, behavior: MockBehavior) {
    super(db, behavior);
  }

  private myOrgId(): string | undefined {
    const me = this.currentUser.id;
    return Object.keys(this.db.orgMembers).find((id) =>
      this.db.orgMembers[id].some((m) => m.userId === me),
    );
  }

  private requireOrg(): Organization {
    const id = this.myOrgId();
    const org = id ? this.db.organizations[id] : undefined;
    if (!org) throw new AppError(ErrorCodes.permissionDenied);
    return org;
  }

  private myRole(orgId: string): BusinessRole | undefined {
    return this.db.orgMembers[orgId]?.find((m) => m.userId === this.currentUser.id)?.role;
  }

  private requireManager(orgId: string): void {
    const role = this.myRole(orgId);
    if (role !== 'owner' && role !== 'dispatcher') throw new AppError(ErrorCodes.orgRoleRequired);
  }

  async getMyOrganization(): Promise<Organization | undefined> {
    await this.gate();
    const id = this.myOrgId();
    return id ? this.db.organizations[id] : undefined;
  }

  async getMembers(): Promise<OrgMember[]> {
    await this.gate();
    const org = this.requireOrg();
    const owner = this.myRole(org.id) === 'owner';
    return (this.db.orgMembers[org.id] ?? []).map((m) =>
      owner ? m : { ...m, earningsToDate: undefined },
    );
  }

  async registerOrganization(options: {
    legalName: string;
    registrationNumber: string;
    idempotencyKey: string;
  }): Promise<Organization> {
    await this.gate();
    const { legalName, registrationNumber, idempotencyKey } = options;
    return this.idempotent('registerOrganization', idempotencyKey, `${legalName}|${registrationNumber}`, () => {
      if (this.myOrgId()) throw new AppError(ErrorCodes.invalidState);
      if (legalName.trim().length < 2 || registrationNumber.trim().length < 4) {
        throw new AppError(ErrorCodes.invalidArgument);
      }
      const me = this.currentUser;
      const org: Organization = {
        id: mockId('org'),
        name: legalName.trim(),
        ownerId: me.id,
        verificationStatus: 'pending',
        payoutAccountSet: false,
        memberCount: 1,
        activeVehicleCount: 0,
      };
      this.db.organizations[org.id] = org;
      this.db.orgMembers[org.id] = [
        {
          userId: me.id,
          displayName: me.displayName,
          role: 'owner',
          verificationStatus: me.providerVerification,
          jobsCompleted: this.db.providers[me.id]?.completedJobs ?? 0,
          earningsToDate: { amountMinor: 0, currency: 'NGN' },
        },
      ];
      this.db.vehicles[org.id] = [];
      return org;
    });
  }

  async getMyInvitations(): Promise<OrgInvitation[]> {
    await this.gate();
    return [...(this.db.orgInvitations[this.currentUser.id] ?? [])];
  }

  async acceptInvitation(organizationId: string, idempotencyKey: string): Promise<Organization> {
    await this.gate();
    return this.idempotent(`acceptInvite:${organizationId}`, idempotencyKey, '', () => {
      const me = this.currentUser;
      const invitations = this.db.orgInvitations[me.id] ?? [];
      const invitation = invitations.find((i) => i.organizationId === organizationId);
      const org = this.db.organizations[organizationId];
      if (!invitation || !org) throw new AppError(ErrorCodes.invalidState);
      if (this.myOrgId()) throw new AppError(ErrorCodes.invalidState);
      this.db.orgInvitations[me.id] = invitations.filter((i) => i.organizationId !== organizationId);
      (this.db.orgMembers[organizationId] ??= []).push({
        userId: me.id,
        displayName: me.displayName,
        role: invitation.role,
        verificationStatus: me.providerVerification,
        jobsCompleted: this.db.providers[me.id]?.completedJobs ?? 0,
      });
      const updated = { ...org, memberCount: org.memberCount + 1 };
      this.db.organizations[organizationId] = updated;
      return updated;
    });
  }

  async inviteMember(options: { phoneE164: string; role: BusinessRole; idempotencyKey: string }): Promise<OrgMember> {
    await this.gate();
    const { phoneE164, role, idempotencyKey } = options;
    return this.idempotent(`invite:${phoneE164}`, idempotencyKey, role, () => {
      const org = this.requireOrg();
      this.requireManager(org.id);
      if (!/^\+\d{8,15}$/.test(phoneE164)) throw new AppError(ErrorCodes.invalidArgument);
      // A number without an account becomes a pending invitation, listed like any other.
      const user = Object.values(this.db.users).find((u) => u.phoneE164 === phoneE164);
      const member: OrgMember = {
        userId: user?.id ?? `invite-${phoneE164}`,
        displayName: user?.displayName ?? phoneE164,
        role,
        verificationStatus: user?.providerVerification ?? 'unverified',
        jobsCompleted: 0,
      };
      if (user) {
        (this.db.orgInvitations[user.id] ??= []).push({
          organizationId: org.id,
          organizationName: org.name,
          role,
          invitedAt: this.now(),
        });
      }
      return member;
    });
  }

  async removeMember(userId: string, idempotencyKey: string): Promise<void> {
    await this.gate();
    return this.idempotent(`removeMember:${userId}`, idempotencyKey, '', () => {
      const org = this.requireOrg();
      if (this.myRole(org.id) !== 'owner') throw new AppError(ErrorCodes.orgRoleRequired);
      if (userId === org.ownerId) throw new AppError(ErrorCodes.invalidState);
      this.db.orgMembers[org.id] = (this.db.orgMembers[org.id] ?? []).filter((m) => m.userId !== userId);
      this.db.organizations[org.id] = { ...org, memberCount: Math.max(1, org.memberCount - 1) };
    });
  }

  async getAssignableJobs(): Promise<JobRequest[]> {
    await this.gate();
    const org = this.requireOrg();
    return (this.db.orgAssignableJobs[org.id] ?? [])
      .map((id) => this.db.requests[id])
      .filter((job): job is JobRequest => job !== undefined);
  }

  async assignJob(options: { jobId: string; workerId: string; idempotencyKey: string }): Promise<JobRequest> {
    await this.gate();
    const { jobId, workerId, idempotencyKey } = options;
    return this.idempotent(`dispatch:${jobId}`, idempotencyKey, workerId, () => {
      const org = this.requireOrg();
      this.requireManager(org.id);
      const pending = this.db.orgAssignableJobs[org.id] ?? [];
      const job = this.db.requests[jobId];
      if (!job || !pending.includes(jobId)) throw new AppError(ErrorCodes.invalidState);
      const worker = this.db.orgMembers[org.id]?.find((m) => m.userId === workerId);
      if (!worker || worker.verificationStatus !== 'verified') {
        throw new AppError(ErrorCodes.workerNotEligible);
      }
      this.db.orgAssignableJobs[org.id] = pending.filter((id) => id !== jobId);
      const updated: JobRequest = { ...job, providerId: workerId, status: 'assigned' };
      this.db.requests[jobId] = updated;
      this.db.jobEvents.emit(updated);
      return updated;
    });
  }

  async getVehicles(): Promise<Vehicle[]> {
    await this.gate();
    const org = this.requireOrg();
    return [...(this.db.vehicles[org.id] ?? [])];
  }

  async upsertVehicle(vehicle: Omit<Vehicle, 'id' | 'organizationId'> & { id?: string }, idempotencyKey: string): Promise<Vehicle> {
    await this.gate();
    return this.idempotent('registerVehicle', idempotencyKey, JSON.stringify(vehicle), () => {
      const org = this.requireOrg();
      this.requireManager(org.id);
      if (vehicle.plate.trim().length < 4) throw new AppError(ErrorCodes.invalidArgument);
      const list = (this.db.vehicles[org.id] ??= []);
      if (vehicle.id && list.some((v) => v.id === vehicle.id)) {
        // A plate is sealed and documents are reviewed: a change is a new registration.
        throw new AppError(ErrorCodes.featureUnavailable);
      }
      const plate = vehicle.plate.trim().toUpperCase();
      const created: Vehicle = {
        id: mockId('veh'),
        organizationId: org.id,
        type: vehicle.type,
        plate: `${plate.slice(0, 3)} •••• ${plate.slice(-3)}`,
        assignedWorkerId: vehicle.assignedWorkerId,
        documentExpiry: vehicle.documentExpiry,
      };
      list.push(created);
      this.db.organizations[org.id] = { ...org, activeVehicleCount: list.length };
      return created;
    });
  }

  async assignVehicle(vehicleId: string, workerId: string | undefined, idempotencyKey: string): Promise<Vehicle> {
    await this.gate();
    return this.idempotent(`assignVehicle:${vehicleId}`, idempotencyKey, workerId ?? '', () => {
      const org = this.requireOrg();
      this.requireManager(org.id);
      const list = this.db.vehicles[org.id] ?? [];
      const index = list.findIndex((v) => v.id === vehicleId);
      if (index < 0) throw new AppError(ErrorCodes.invalidState);
      const updated = { ...list[index], assignedWorkerId: workerId };
      list[index] = updated;
      return updated;
    });
  }
}
