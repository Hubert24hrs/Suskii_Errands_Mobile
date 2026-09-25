// Request + offer repositories (customer scope). Mirrors
// MockRequestRepository / MockOfferRepository and the offer-negotiation
// state machine (docs/plan/state-machines/offer-negotiation.md):
// the counterparty accepts/declines/counters, rounds and TTL come from the
// category, accepting expires siblings in one transaction, and losing
// callers get ERR_OFFER_NOT_ACTIVE / ERR_OFFER_EXPIRED /
// ERR_OFFER_NOT_YOUR_TURN.

import { roundHalfEven, simulateQuote } from '../behavior';
import { AppError, ErrorCodes } from '../errors';
import type { MockDatabase } from '../fixtures';
import type { MockBehavior } from '../behavior';
import {
  isTerminalJobStatus,
  type CreateRequestInput,
  type JobRequest,
  type JobStatus,
  type Money,
  type Offer,
  type ServiceCategory,
  type TrustLevel,
  type UpdateRequestInput,
} from '../types';
import { MockRepo, type Unsubscribe } from './base';

const CANCELLABLE: ReadonlySet<JobStatus> = new Set([
  'draft',
  'published',
  'offers_received',
  'negotiating',
  'agreed',
  'payment_pending',
]);

export class MockRequestRepository extends MockRepo {
  constructor(db: MockDatabase, behavior: MockBehavior) {
    super(db, behavior);
  }

  async getMyActiveJobs(): Promise<JobRequest[]> {
    await this.gate();
    return Object.values(this.db.requests)
      .filter((r) => r.customerId === this.currentUser.id && !isTerminalJobStatus(r.status))
      .sort((a, b) => b.createdAt.getTime() - a.createdAt.getTime());
  }

  async getMyRequestHistory(options?: {
    cursor?: string;
    limit?: number;
  }): Promise<JobRequest[]> {
    await this.gate();
    const limit = options?.limit ?? 20;
    const history = Object.values(this.db.requests)
      .filter((r) => r.customerId === this.currentUser.id && isTerminalJobStatus(r.status))
      .sort((a, b) => b.createdAt.getTime() - a.createdAt.getTime());
    const start = options?.cursor
      ? history.findIndex((r) => r.id === options.cursor) + 1
      : 0;
    return history.slice(start, start + limit);
  }

  /** Emits the current job (if any) immediately, then every change. */
  watchJob(jobId: string, onChange: (job: JobRequest) => void): Unsubscribe {
    const current = this.db.requests[jobId];
    if (current) onChange(current);
    return this.db.jobEvents.subscribe((r) => {
      if (r.id === jobId) onChange(r);
    });
  }

  /**
   * Always creates a DRAFT. Unverified customers may draft (and use the
   * concierge); verification gates publishing, not creating.
   */
  async createRequest(
    input: CreateRequestInput,
    idempotencyKey: string,
  ): Promise<JobRequest> {
    await this.gate();
    return this.idempotent('createRequest', idempotencyKey, JSON.stringify(input), () => {
      const user = this.currentUser;
      const id = `req-${Date.now()}`;
      const request: JobRequest = {
        id,
        customerId: user.id,
        categoryId: input.categoryId,
        isCustomCategory: input.isCustomCategory ?? false,
        description: input.description,
        mediaPaths: input.mediaPaths ?? [],
        pickup: input.pickup,
        destination: input.destination,
        urgency: input.urgency ?? 'standard',
        status: 'draft',
        createdAt: this.now(),
        scheduledAt: input.scheduledAt,
        preferredPrice: input.preferredPrice,
        itemFloat: input.itemFloat,
        declaredValue: input.declaredValue,
      };
      this.db.requests[id] = request;
      this.db.jobEvents.emit(request);
      return request;
    });
  }

  /** Edits a draft. Anything past draft is a server-side ERR_INVALID_STATE. */
  async updateDraft(
    jobId: string,
    patch: UpdateRequestInput,
    idempotencyKey: string,
  ): Promise<JobRequest> {
    await this.gate();
    return this.idempotent(`updateDraft:${jobId}`, idempotencyKey, JSON.stringify(patch), () => {
      const request = this.db.requests[jobId];
      if (!request || request.customerId !== this.currentUser.id) {
        throw new AppError(ErrorCodes.unknown);
      }
      if (request.status !== 'draft') {
        throw new AppError(ErrorCodes.invalidState);
      }
      const updated: JobRequest = { ...request, ...patch };
      this.db.requests[jobId] = updated;
      this.db.jobEvents.emit(updated);
      return updated;
    });
  }

  /**
   * DRAFT → PUBLISHED. Throws ERR_VERIFICATION_REQUIRED when the customer is
   * not verified, so the UI routes to the verification flow.
   */
  async publishRequest(jobId: string, idempotencyKey: string): Promise<JobRequest> {
    await this.gate();
    return this.idempotent(`publishRequest:${jobId}`, idempotencyKey, '', () => {
      const user = this.currentUser;
      if (user.customerVerification !== 'verified') {
        throw new AppError(ErrorCodes.verificationRequired);
      }
      const request = this.db.requests[jobId];
      if (!request || request.status !== 'draft') {
        throw new AppError(ErrorCodes.permissionDenied);
      }
      const updated: JobRequest = {
        ...request,
        status: 'published',
        expiresAt: new Date(this.now().getTime() + 4 * 3_600_000),
      };
      this.db.requests[jobId] = updated;
      this.db.jobEvents.emit(updated);
      return updated;
    });
  }

  /** Cancellation is a server decision (fees depend on state and timing). */
  async cancelRequest(
    jobId: string,
    reasonKey: string,
    idempotencyKey: string,
  ): Promise<JobRequest> {
    await this.gate();
    return this.idempotent(`cancelRequest:${jobId}`, idempotencyKey, reasonKey, () => {
      const request = this.db.requests[jobId];
      if (!request) throw new AppError(ErrorCodes.unknown);
      if (!CANCELLABLE.has(request.status)) {
        throw new AppError(ErrorCodes.jobNotCancellable);
      }
      const updated: JobRequest = { ...request, status: 'cancelled' };
      this.db.requests[jobId] = updated;
      this.db.jobEvents.emit(updated);
      return updated;
    });
  }
}

/** Simulated incoming-offer candidates (provider, rating, trust, ×base, m, min). */
const OFFER_CANDIDATES: ReadonlyArray<
  readonly [string, string, number, TrustLevel, number, number, number]
> = [
  ['provider-ngozi', 'Ngozi Adeyemi', 4.9, 'elite', 1.05, 1500, 9],
  ['provider-kwame', 'Kwame Asante', 4.6, 'verified', 0.92, 3100, 18],
  ['provider-musa', 'Musa Bello', 4.7, 'verified', 1.18, 800, 6],
];

const COLLECTING: ReadonlySet<JobStatus> = new Set([
  'published',
  'offers_received',
  'negotiating',
]);

export class MockOfferRepository extends MockRepo {
  constructor(db: MockDatabase, behavior: MockBehavior) {
    super(db, behavior);
  }

  private category(categoryId: string): ServiceCategory {
    return (
      this.db.categories.find((c) => c.id === categoryId) ??
      this.db.categories[this.db.categories.length - 1]
    );
  }

  private offerTtlMs(categoryId: string): number {
    return (
      this.behavior.offerTtlOverrideMs ??
      this.category(categoryId).offerTtlSeconds * 1000
    );
  }

  private maxRounds(categoryId: string): number {
    return this.category(categoryId).maxCounterRounds;
  }

  /**
   * Emits the offer list immediately, then on every change. While the
   * request is collecting, 2–3 simulated incoming offers arrive staggered;
   * a TTL worker flips pending/countered offers past expiresAt to expired.
   * All timers are per-subscription and cancelled on unsubscribe.
   */
  watchOffers(requestId: string, onChange: (offers: Offer[]) => void): Unsubscribe {
    const timers = new Set<ReturnType<typeof setTimeout>>();
    const emit = () =>
      onChange([...(this.db.offers[requestId] ?? [])].map((o) => ({ ...o })));
    emit();

    const request = this.db.requests[requestId];
    if (request && COLLECTING.has(request.status)) {
      const existing = this.db.offers[requestId] ?? [];
      const base = request.preferredPrice ?? { amountMinor: 400000, currency: 'NGN' };
      const candidates = OFFER_CANDIDATES.filter(
        (c) => !existing.some((o) => o.providerId === c[0]),
      );
      candidates.forEach((c, i) => {
        const delay = this.behavior.offerArrivalDelaysMs[i];
        if (delay === undefined) return;
        const timer = setTimeout(() => {
          const current = this.db.requests[requestId];
          if (!current || !COLLECTING.has(current.status)) return;
          const amount: Money = {
            amountMinor: Math.round(base.amountMinor * c[4]),
            currency: base.currency,
          };
          const offer: Offer = {
            id: `offer-live-${Date.now()}-${i}`,
            requestId,
            providerId: c[0],
            providerName: c[1],
            providerRating: c[2],
            providerTrustLevel: c[3],
            amount,
            status: 'pending',
            round: 1,
            createdAt: this.now(),
            message: 'I can start immediately.',
            distanceMeters: c[5],
            etaMinutes: c[6],
            payoutEstimate: simulateQuote(amount, {
              estimatedGatewayFee: {
                amountMinor: roundHalfEven(amount.amountMinor * 15, 1000),
                currency: amount.currency,
              },
            }),
            expiresAt: new Date(this.now().getTime() + this.offerTtlMs(current.categoryId)),
          };
          (this.db.offers[requestId] ??= []).push(offer);
          this.db.offerEvents.emit(offer);
          // State machine: first offer moves PUBLISHED → OFFERS_RECEIVED.
          if (current.status === 'published') {
            const updated: JobRequest = { ...current, status: 'offers_received' };
            this.db.requests[requestId] = updated;
            this.db.jobEvents.emit(updated);
          }
          emit();
        }, delay);
        timers.add(timer);
      });
    }

    // TTL worker: expiry has no client entry point — this plays the
    // scheduled worker, evaluating against the server clock.
    const ttlWorker = setInterval(() => {
      const list = this.db.offers[requestId];
      if (!list) return;
      let changed = false;
      for (let i = 0; i < list.length; i++) {
        const o = list[i];
        const live = o.status === 'pending' || o.status === 'countered';
        if (live && o.expiresAt && o.expiresAt.getTime() < this.now().getTime()) {
          list[i] = { ...o, status: 'expired' };
          this.db.offerEvents.emit(list[i]);
          changed = true;
        }
      }
      if (changed) emit();
    }, 500);
    timers.add(ttlWorker);

    return () => {
      for (const t of timers) {
        clearTimeout(t);
        clearInterval(t);
      }
      timers.clear();
    };
  }

  private find(offerId: string): { requestId: string; index: number; offer: Offer } {
    for (const [requestId, list] of Object.entries(this.db.offers)) {
      const index = list.findIndex((o) => o.id === offerId);
      if (index >= 0) return { requestId, index, offer: list[index] };
    }
    throw new AppError(ErrorCodes.unknown);
  }

  /** Throws the right "this offer is not actionable" error. */
  private assertActionable(offer: Offer, requestId: string): void {
    const list = this.db.offers[requestId] ?? [];
    const siblingAccepted = list.some((o) => o.id !== offer.id && o.status === 'accepted');
    if (siblingAccepted) {
      throw new AppError(ErrorCodes.offerNotActive);
    }
    if (
      offer.status === 'expired' ||
      (offer.expiresAt !== undefined && offer.expiresAt.getTime() < this.now().getTime())
    ) {
      throw new AppError(ErrorCodes.offerExpired);
    }
    if (offer.status === 'countered') {
      // The live offer in this thread is the customer's own counter —
      // accepting/declining/countering is the provider's move now.
      throw new AppError(ErrorCodes.offerNotYourTurn);
    }
    if (offer.status !== 'pending') {
      throw new AppError(ErrorCodes.offerNotActive);
    }
  }

  /** One transaction: accept, expire all siblings, agree the job. */
  async acceptOffer(offerId: string, idempotencyKey: string): Promise<Offer> {
    await this.gate();
    return this.idempotent(`acceptOffer:${offerId}`, idempotencyKey, '', () => {
      const { requestId, index, offer } = this.find(offerId);
      this.assertActionable(offer, requestId);
      const list = this.db.offers[requestId];
      const accepted: Offer = { ...offer, status: 'accepted' };
      list[index] = accepted;
      for (let i = 0; i < list.length; i++) {
        if (i !== index && (list[i].status === 'pending' || list[i].status === 'countered')) {
          list[i] = { ...list[i], status: 'expired' };
        }
      }
      const request = this.db.requests[requestId];
      const updated: JobRequest = {
        ...request,
        status: 'agreed',
        agreedPrice: accepted.amount,
        agreedBreakdown: simulateQuote(accepted.amount),
        providerId: accepted.providerId,
      };
      this.db.requests[requestId] = updated;
      this.db.jobEvents.emit(updated);
      this.db.offerEvents.emit(accepted);
      return accepted;
    });
  }

  async declineOffer(offerId: string, idempotencyKey: string): Promise<Offer> {
    await this.gate();
    return this.idempotent(`declineOffer:${offerId}`, idempotencyKey, '', () => {
      const { requestId, index, offer } = this.find(offerId);
      this.assertActionable(offer, requestId);
      const declined: Offer = { ...offer, status: 'declined' };
      this.db.offers[requestId][index] = declined;
      this.db.offerEvents.emit(declined);
      return declined;
    });
  }

  /**
   * Customer counters a provider's pending offer. TTL resets so the provider
   * has time to respond; the mock provider then accepts (≥90% of its ask),
   * counters back at the midpoint, or declines when rounds run out.
   */
  async counterOffer(options: {
    offerId: string;
    amount: Money;
    idempotencyKey: string;
    message?: string;
  }): Promise<Offer> {
    await this.gate();
    const { offerId, amount, idempotencyKey, message } = options;
    return this.idempotent(
      `counterOffer:${offerId}`,
      idempotencyKey,
      `${amount.amountMinor} ${amount.currency}|${message ?? ''}`,
      () => {
        const { requestId, index, offer } = this.find(offerId);
        const request = this.db.requests[requestId];
        if (!request) throw new AppError(ErrorCodes.unknown);
        const categoryId = request.categoryId;
        if (offer.round >= this.maxRounds(categoryId)) {
          throw new AppError(ErrorCodes.offerRoundsExhausted);
        }
        this.assertActionable(offer, requestId);
        if (amount.amountMinor <= 0 || !Number.isSafeInteger(amount.amountMinor)) {
          throw new AppError(ErrorCodes.priceOutOfRange);
        }
        const providerAsk = offer.amount.amountMinor;
        const countered: Offer = {
          ...offer,
          status: 'countered',
          amount,
          message,
          round: offer.round + 1,
          expiresAt: new Date(this.now().getTime() + this.offerTtlMs(categoryId)),
        };
        this.db.offers[requestId][index] = countered;
        this.db.offerEvents.emit(countered);
        if (request.status === 'offers_received' || request.status === 'published') {
          const negotiating: JobRequest = { ...request, status: 'negotiating' };
          this.db.requests[requestId] = negotiating;
          this.db.jobEvents.emit(negotiating);
        }
        this.scheduleProviderResponse(requestId, countered.id, providerAsk, categoryId);
        return countered;
      },
    );
  }

  /**
   * The mock counterparty. Server-side: it acts on the customer's counter
   * after a delay — accept at ≥90% of its ask, counter at the midpoint while
   * rounds remain, otherwise decline.
   */
  private scheduleProviderResponse(
    requestId: string,
    offerId: string,
    providerAsk: number,
    categoryId: string,
  ): void {
    setTimeout(() => {
      const list = this.db.offers[requestId];
      const index = list?.findIndex((o) => o.id === offerId) ?? -1;
      if (!list || index < 0) return;
      const offer = list[index];
      // Only a still-live customer counter is actionable (customer may have
      // withdrawn; expiry worker may have fired).
      if (offer.status !== 'countered') return;
      const request = this.db.requests[requestId];
      if (!request || !COLLECTING.has(request.status)) return;
      if (offer.amount.amountMinor >= roundHalfEven(providerAsk * 9, 10)) {
        // Provider accepts the customer's counter — same transaction shape
        // as acceptOffer: expire siblings, agree the job, set the PIN.
        const accepted: Offer = { ...offer, status: 'accepted' };
        list[index] = accepted;
        for (let i = 0; i < list.length; i++) {
          if (i !== index && (list[i].status === 'pending' || list[i].status === 'countered')) {
            list[i] = { ...list[i], status: 'expired' };
          }
        }
        const updated: JobRequest = {
          ...request,
          status: 'agreed',
          agreedPrice: accepted.amount,
          agreedBreakdown: simulateQuote(accepted.amount),
          providerId: accepted.providerId,
        };
        this.db.requests[requestId] = updated;
        this.db.jobEvents.emit(updated);
        this.db.offerEvents.emit(accepted);
        return;
      }
      if (offer.round < this.maxRounds(categoryId)) {
        const counterAmount: Money = {
          amountMinor: roundHalfEven(providerAsk + offer.amount.amountMinor, 2),
          currency: offer.amount.currency,
        };
        const countered: Offer = {
          ...offer,
          status: 'pending',
          amount: counterAmount,
          message: 'Meet me in the middle.',
          round: offer.round + 1,
          expiresAt: new Date(this.now().getTime() + this.offerTtlMs(categoryId)),
        };
        list[index] = countered;
        this.db.offerEvents.emit(countered);
        return;
      }
      const declined: Offer = { ...offer, status: 'declined' };
      list[index] = declined;
      this.db.offerEvents.emit(declined);
    }, this.behavior.providerResponseDelayMs);
  }

  /**
   * Author pulls a live offer. In the customer scope the customer authored
   * the offer only while it is their counter on the table (`countered`);
   * withdrawing a provider's offer is ERR_OFFER_NOT_YOUR_TURN.
   */
  async withdrawOffer(offerId: string, idempotencyKey: string): Promise<Offer> {
    await this.gate();
    return this.idempotent(`withdrawOffer:${offerId}`, idempotencyKey, '', () => {
      const { requestId, index, offer } = this.find(offerId);
      if (offer.status === 'pending') {
        throw new AppError(ErrorCodes.offerNotYourTurn);
      }
      if (offer.status !== 'countered') {
        throw new AppError(ErrorCodes.offerNotActive);
      }
      const withdrawn: Offer = { ...offer, status: 'withdrawn' };
      this.db.offers[requestId][index] = withdrawn;
      this.db.offerEvents.emit(withdrawn);
      return withdrawn;
    });
  }
}
