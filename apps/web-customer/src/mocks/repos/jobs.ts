// Payment, tracking, chat, rating and safety repositories (customer scope).
// The client never marks anything paid/delivered itself — status flips
// arrive as events from the simulated gateway webhook / server verify.

import { AppError, ErrorCodes } from '../errors';
import type { MockDatabase } from '../fixtures';
import type { MockBehavior } from '../behavior';
import type {
  ChatMessage,
  ChatMessageType,
  GeoPoint,
  JobRequest,
  JobStatus,
  Payment,
  PaymentMethod,
  PaymentSession,
  Rating,
  SosAlert,
  TripShare,
} from '../types';
import { MockRepo, type Unsubscribe } from './base';

const PAYMENT_TTL_MS = 15 * 60_000;

export class MockPaymentRepository extends MockRepo {
  constructor(db: MockDatabase, behavior: MockBehavior) {
    super(db, behavior);
  }

  private readonly timers = new Set<ReturnType<typeof setTimeout>>();

  async getPaymentForJob(jobId: string): Promise<Payment | undefined> {
    await this.gate();
    const id = this.db.paymentByJob[jobId];
    return id ? this.db.payments[id] : undefined;
  }

  /** Emits the current payment (or undefined) immediately, then changes. */
  watchPaymentForJob(
    jobId: string,
    onChange: (payment: Payment | undefined) => void,
  ): Unsubscribe {
    const id = this.db.paymentByJob[jobId];
    onChange(id ? this.db.payments[id] : undefined);
    return this.db.paymentEvents.subscribe((p) => {
      if (p.jobId === jobId) onChange(p);
    });
  }

  private setJob(jobId: string, patch: Partial<JobRequest>): void {
    const job = this.db.requests[jobId];
    if (!job) return;
    const updated: JobRequest = { ...job, ...patch };
    this.db.requests[jobId] = updated;
    this.db.jobEvents.emit(updated);
  }

  private setPayment(payment: Payment): void {
    this.db.payments[payment.id] = payment;
    this.db.paymentEvents.emit(payment);
  }

  /**
   * Throws ERR_VERIFICATION_REQUIRED for unverified customers and
   * ERR_INVALID_STATE unless the job is AGREED (first attempt) or
   * PAYMENT_PENDING (retry within the TTL). The simulated webhook flips the
   * payment to HELD (or FAILED with failure injection) after
   * `paymentConfirmDelayMs`; a pending payment past its TTL fails with
   * `paymentTtlExpired`.
   */
  async initializePayment(options: {
    jobId: string;
    method: PaymentMethod;
    idempotencyKey: string;
  }): Promise<PaymentSession> {
    await this.gate();
    const { jobId, method, idempotencyKey } = options;
    return this.idempotent(`initializePayment:${jobId}`, idempotencyKey, method, () => {
      const user = this.currentUser;
      if (user.customerVerification !== 'verified') {
        throw new AppError(ErrorCodes.verificationRequired);
      }
      const job = this.db.requests[jobId];
      if (!job) throw new AppError(ErrorCodes.unknown);
      if (job.customerId !== user.id) {
        throw new AppError(ErrorCodes.permissionDenied);
      }
      const agreed = job.agreedPrice;
      if (!agreed || (job.status !== 'agreed' && job.status !== 'payment_pending')) {
        throw new AppError(ErrorCodes.invalidState);
      }
      const existingId = this.db.paymentByJob[jobId];
      const existing = existingId ? this.db.payments[existingId] : undefined;
      if (existing && existing.status === 'held') {
        throw new AppError(ErrorCodes.invalidState);
      }
      const sessionFor = (payment: Payment): PaymentSession => ({
        payment,
        ussdCode: method === 'ussd' ? '*737*000#...' : undefined,
        reference: method === 'bank_transfer' ? payment.gatewayReference : undefined,
      });
      // Retry within the TTL: return the in-flight payment (same as the
      // server returning the existing pending attempt).
      if (existing && existing.status === 'pending') {
        return sessionFor(existing);
      }
      const id = `pay-${Date.now()}`;
      const payment: Payment = {
        id,
        jobId,
        amount: agreed,
        method,
        status: 'pending',
        createdAt: this.now(),
        gatewayReference: `FLW-MOCK-${id}`,
        expiresAt: new Date(this.now().getTime() + PAYMENT_TTL_MS),
      };
      this.db.payments[id] = payment;
      this.db.paymentByJob[jobId] = id;
      this.setJob(jobId, { status: 'payment_pending', expiresAt: payment.expiresAt });
      this.db.paymentEvents.emit(payment);

      // Simulated gateway webhook + server-side verify.
      const confirmTimer = setTimeout(() => {
        if (this.behavior.failNextPayment) {
          this.behavior.failNextPayment = false;
          this.setPayment({
            ...this.db.payments[id],
            status: 'failed',
            failureReasonKey: 'paymentDeclined',
          });
          // Back to AGREED so the customer can re-attempt payment.
          this.setJob(jobId, { status: 'agreed' });
          return;
        }
        const current = this.db.payments[id];
        if (current.status !== 'pending') return;
        this.setPayment({ ...current, status: 'held', paidAt: this.now() });
        this.setJob(jobId, { status: 'paid_held' });
      }, this.behavior.paymentConfirmDelayMs);
      this.timers.add(confirmTimer);

      // Payment TTL worker: an unconfirmed payment expires and the job
      // returns to AGREED for a fresh attempt.
      if (payment.expiresAt) {
        const expiryTimer = setTimeout(
          () => {
            const current = this.db.payments[id];
            if (current.status !== 'pending') return;
            this.setPayment({
              ...current,
              status: 'failed',
              failureReasonKey: 'paymentTtlExpired',
            });
            this.setJob(jobId, { status: 'agreed' });
          },
          payment.expiresAt.getTime() - this.now().getTime(),
        );
        this.timers.add(expiryTimer);
      }

      return sessionFor(payment);
    });
  }
}

/** Straight-line demo route (Lekki → Admiralty) for the tracking stream. */
const TRACK_START: GeoPoint = { latitude: 6.4281, longitude: 3.4219 };
const TRACK_END: GeoPoint = { latitude: 6.4311, longitude: 3.4359 };
const TRACK_STEPS = 30;

export class MockTrackingRepository extends MockRepo {
  /**
   * Live provider location for an active job (Realtime Broadcast on the
   * backend; sampled mock ticks for now). Emits every 2s for 30 steps.
   */
  watchProviderLocation(jobId: string, onChange: (point: GeoPoint) => void): Unsubscribe {
    let step = 0;
    const timer = setInterval(() => {
      step = Math.min(step + 1, TRACK_STEPS);
      const t = step / TRACK_STEPS;
      onChange({
        latitude: TRACK_START.latitude + (TRACK_END.latitude - TRACK_START.latitude) * t,
        longitude: TRACK_START.longitude + (TRACK_END.longitude - TRACK_START.longitude) * t,
      });
      if (step >= TRACK_STEPS) clearInterval(timer);
    }, 2000);
    return () => clearInterval(timer);
  }
}

/** Chat is open while the parties are in contact or the job is executing. */
const CHAT_OPEN_STATUSES: ReadonlySet<JobStatus> = new Set([
  'paid_held',
  'assigned',
  'en_route',
  'arrived',
  'in_progress',
  'completed_by_provider',
]);

const CHAT_AFTER_CONFIRM_STATUSES: ReadonlySet<JobStatus> = new Set([
  'confirmed',
  'settled',
  'closed',
  'disputed',
]);

const CHAT_WINDOW_AFTER_CONFIRM_MS = 24 * 3_600_000;

export class MockChatRepository extends MockRepo {
  constructor(db: MockDatabase, behavior: MockBehavior) {
    super(db, behavior);
  }

  /**
   * Chat opens at PAID_HELD and closes 24h after confirmation — unless a
   * dispute is open, which keeps the thread alive for evidence.
   */
  private isChatOpen(job: JobRequest): boolean {
    if (CHAT_OPEN_STATUSES.has(job.status)) return true;
    const dispute = this.db.disputes[job.id];
    const disputeOpen =
      dispute !== undefined && (dispute.status === 'open' || dispute.status === 'in_review');
    if (disputeOpen && CHAT_AFTER_CONFIRM_STATUSES.has(job.status)) return true;
    if (CHAT_AFTER_CONFIRM_STATUSES.has(job.status)) {
      const confirmedAt = this.db.jobConfirmedAt[job.id];
      if (
        confirmedAt &&
        this.now().getTime() - confirmedAt.getTime() < CHAT_WINDOW_AFTER_CONFIRM_MS
      ) {
        return true;
      }
    }
    return false;
  }

  /** Emits the full message list immediately, then on every change. */
  watchMessages(jobId: string, onChange: (messages: ChatMessage[]) => void): Unsubscribe {
    onChange([...(this.db.chats[jobId] ?? [])]);
    return this.db.chatEvents.subscribe((changedJobId) => {
      if (changedJobId === jobId) onChange([...(this.db.chats[jobId] ?? [])]);
    });
  }

  private validatePayload(
    type: ChatMessageType,
    payload: { text?: string; mediaPath?: string; location?: GeoPoint; offerId?: string },
  ): void {
    switch (type) {
      case 'text':
        if (!payload.text || payload.text.trim() === '') {
          throw new AppError(ErrorCodes.invalidState);
        }
        return;
      case 'image':
      case 'voice_note':
        if (!payload.mediaPath) throw new AppError(ErrorCodes.invalidState);
        return;
      case 'location':
        if (!payload.location) throw new AppError(ErrorCodes.invalidState);
        return;
      case 'offer_card':
        if (!payload.offerId) throw new AppError(ErrorCodes.invalidState);
        return;
      case 'system':
        // System messages are server-authored only.
        throw new AppError(ErrorCodes.permissionDenied);
    }
  }

  async sendMessage(options: {
    jobId: string;
    type: ChatMessageType;
    idempotencyKey: string;
    text?: string;
    mediaPath?: string;
    location?: GeoPoint;
    offerId?: string;
  }): Promise<ChatMessage> {
    await this.gate();
    const { jobId, type, idempotencyKey, ...payload } = options;
    return this.idempotent(
      `chatSend:${jobId}`,
      idempotencyKey,
      `${type}|${payload.text ?? ''}|${payload.mediaPath ?? ''}`,
      () => {
        const job = this.db.requests[jobId];
        if (!job) throw new AppError(ErrorCodes.unknown);
        if (job.customerId !== this.currentUser.id && job.providerId !== this.currentUser.id) {
          throw new AppError(ErrorCodes.permissionDenied);
        }
        if (!this.isChatOpen(job)) throw new AppError(ErrorCodes.chatClosed);
        this.validatePayload(type, payload);
        const message: ChatMessage = {
          id: `msg-${Date.now()}`,
          jobId,
          senderId: this.currentUser.id,
          type,
          createdAt: this.now(),
          text: payload.text,
          mediaPath: payload.mediaPath,
          location: payload.location,
          offerId: payload.offerId,
        };
        (this.db.chats[jobId] ??= []).push(message);
        this.db.chatEvents.emit(jobId);
        return message;
      },
    );
  }

  /** Read receipts: marks the counterparty's messages as read. */
  async markMessagesRead(jobId: string, idempotencyKey: string): Promise<void> {
    await this.gate();
    return this.idempotent(`chatRead:${jobId}`, idempotencyKey, '', () => {
      const messages = this.db.chats[jobId] ?? [];
      const at = this.now();
      let changed = false;
      for (let i = 0; i < messages.length; i++) {
        if (messages[i].senderId !== this.currentUser.id && !messages[i].readAt) {
          messages[i] = { ...messages[i], readAt: at };
          changed = true;
        }
      }
      if (changed) this.db.chatEvents.emit(jobId);
    });
  }
}

const RATEABLE: ReadonlySet<JobStatus> = new Set(['confirmed', 'settled', 'closed']);

export class MockRatingRepository extends MockRepo {
  /**
   * Ratings are blind: each party's rating becomes visible to the other only
   * after both have rated or the blind window ends (server-side). This
   * repository only ever returns the current user's own rating.
   */
  async getMyRatingForJob(jobId: string): Promise<Rating | undefined> {
    await this.gate();
    const user = this.currentUser;
    return (this.db.ratings[jobId] ?? []).find((r) => r.raterId === user.id);
  }

  /** One rating per party per job; stars 1–5; rateable states only. */
  async submitRating(options: {
    jobId: string;
    stars: number;
    idempotencyKey: string;
    tagKeys?: string[];
    comment?: string;
  }): Promise<Rating> {
    await this.gate();
    const { jobId, stars, idempotencyKey, tagKeys = [], comment } = options;
    return this.idempotent(
      `submitRating:${jobId}`,
      idempotencyKey,
      `${stars}|${tagKeys.join(',')}|${comment ?? ''}`,
      () => {
        const user = this.currentUser;
        const job = this.db.requests[jobId];
        if (!job) throw new AppError(ErrorCodes.unknown);
        const isCustomer = job.customerId === user.id;
        const isProvider = job.providerId === user.id;
        if (!isCustomer && !isProvider) {
          throw new AppError(ErrorCodes.permissionDenied);
        }
        if (!RATEABLE.has(job.status) || stars < 1 || stars > 5) {
          throw new AppError(ErrorCodes.invalidState);
        }
        const list = (this.db.ratings[jobId] ??= []);
        if (list.some((r) => r.raterId === user.id)) {
          throw new AppError(ErrorCodes.invalidState);
        }
        const rating: Rating = {
          id: `rating-${Date.now()}`,
          jobId,
          raterId: user.id,
          rateeId: isCustomer ? (job.providerId as string) : job.customerId,
          stars,
          tagKeys,
          comment,
          createdAt: this.now(),
        };
        list.push(rating);
        return rating;
      },
    );
  }
}

/** States in which SOS / trip sharing make sense (agreed onward). */
const ACTIVE_JOB_STATES: ReadonlySet<JobStatus> = new Set([
  'agreed',
  'payment_pending',
  'paid_held',
  'assigned',
  'en_route',
  'arrived',
  'in_progress',
  'completed_by_provider',
]);

export class MockSafetyRepository extends MockRepo {
  constructor(db: MockDatabase, behavior: MockBehavior) {
    super(db, behavior);
  }

  private participantJob(jobId: string): JobRequest {
    const user = this.currentUser;
    const job = this.db.requests[jobId];
    if (!job) throw new AppError(ErrorCodes.unknown);
    if (job.customerId !== user.id && job.providerId !== user.id) {
      throw new AppError(ErrorCodes.permissionDenied);
    }
    if (!ACTIVE_JOB_STATES.has(job.status)) {
      throw new AppError(ErrorCodes.invalidState);
    }
    return job;
  }

  /**
   * SOS is naturally idempotent: a second trigger while one is active
   * returns the same alert rather than piling up alerts.
   */
  async triggerSos(options: {
    jobId: string;
    idempotencyKey: string;
    location?: GeoPoint;
  }): Promise<SosAlert> {
    await this.gate();
    const { jobId, idempotencyKey, location } = options;
    return this.idempotent(
      `triggerSos:${jobId}`,
      idempotencyKey,
      location ? `${location.latitude},${location.longitude}` : '',
      () => {
        const user = this.currentUser;
        this.participantJob(jobId);
        const existing = this.db.sosAlerts[jobId];
        if (existing && existing.status === 'active') return existing;
        const alert: SosAlert = {
          id: `sos-${Date.now()}`,
          jobId,
          triggeredBy: user.id,
          status: 'active',
          createdAt: this.now(),
          location,
          // The mock "server" notifies the user's trusted contacts.
          trustedContactsNotified: (this.db.trustedContacts[user.id] ?? []).length,
        };
        this.db.sosAlerts[jobId] = alert;
        this.db.sosEvents.emit(alert);
        return alert;
      },
    );
  }

  /** Emits the open alert for a job (or undefined), then every change. */
  watchActiveSos(jobId: string, onChange: (alert: SosAlert | undefined) => void): Unsubscribe {
    const current = this.db.sosAlerts[jobId];
    onChange(current && current.status === 'active' ? current : undefined);
    return this.db.sosEvents.subscribe((a) => {
      if (a.jobId === jobId) onChange(a.status === 'active' ? a : undefined);
    });
  }

  async createTripShareLink(jobId: string, idempotencyKey: string): Promise<TripShare> {
    await this.gate();
    return this.idempotent(`tripShare:${jobId}`, idempotencyKey, '', () => {
      this.participantJob(jobId);
      return {
        url: `https://track.suskii.invalid/t/${jobId}`,
        expiresAt: new Date(this.now().getTime() + 3_600_000),
      };
    });
  }
}

/**
 * Job-progress actions (mirrors JobProgressRepository). Customer scope: only
 * confirmCompletion — the provider-side verbs (requestStatusChange,
 * verifyHandoverPin) stay out of the customer app.
 */
export class MockJobProgressRepository extends MockRepo {
  constructor(db: MockDatabase, behavior: MockBehavior) {
    super(db, behavior);
  }

  /**
   * Customer confirms completion (mirrors the Dart mock): customer-only,
   * only from COMPLETED_BY_PROVIDER. The Dart mock releases no funds here —
   * settlement is a separate server-side step — so the held payment is left
   * untouched. Records the confirmation time so the chat 24h window works.
   */
  async confirmCompletion(jobId: string, idempotencyKey: string): Promise<JobRequest> {
    await this.gate();
    return this.idempotent(`confirmCompletion:${jobId}`, idempotencyKey, '', () => {
      const request = this.db.requests[jobId];
      if (!request) throw new AppError(ErrorCodes.unknown);
      if (request.customerId !== this.currentUser.id) {
        throw new AppError(ErrorCodes.permissionDenied);
      }
      if (request.status !== 'completed_by_provider') {
        throw new AppError(ErrorCodes.invalidState);
      }
      const confirmedAt = this.now();
      const updated: JobRequest = { ...request, status: 'confirmed' };
      this.db.requests[jobId] = updated;
      this.db.jobConfirmedAt[jobId] = confirmedAt;
      this.db.jobEvents.emit(updated);
      return updated;
    });
  }
}
