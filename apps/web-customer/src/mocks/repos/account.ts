// Wallet, referral, promo, dispute, support and settings repositories
// (customer scope). All balances, refunds and resolutions are
// server-decided; the client only requests and renders.

import { AppError, ErrorCodes } from '../errors';
import type { MockDatabase } from '../fixtures';
import type { MockBehavior } from '../behavior';
import type {
  Dispute,
  JobStatus,
  Money,
  NotificationPreferences,
  Promo,
  ReferralSummary,
  SupportTicket,
  TrustedContact,
  WalletSummary,
  WalletTransaction,
  WalletTransactionStatus,
} from '../types';
import { MockRepo, type Unsubscribe } from './base';

export class MockWalletRepository extends MockRepo {
  constructor(db: MockDatabase, behavior: MockBehavior) {
    super(db, behavior);
  }

  private currency(): string {
    return this.db.countryPacks[this.currentUser.countryCode]?.currencyCode ?? 'NGN';
  }

  async getSummary(): Promise<WalletSummary> {
    await this.gate();
    return (
      this.db.wallets[this.currentUser.id] ?? {
        available: { amountMinor: 0, currency: this.currency() },
        pending: { amountMinor: 0, currency: this.currency() },
      }
    );
  }

  async getTransactions(options?: {
    cursor?: string;
    limit?: number;
  }): Promise<WalletTransaction[]> {
    await this.gate();
    const limit = options?.limit ?? 20;
    const sorted = [...(this.db.walletTransactions[this.currentUser.id] ?? [])].sort(
      (a, b) => b.createdAt.getTime() - a.createdAt.getTime(),
    );
    // Cursor is the last row's createdAt (ISO-8601) — an opaque page token,
    // matching the Supabase impl's created_at keyset.
    const all = options?.cursor
      ? sorted.filter((t) => t.createdAt.getTime() < Date.parse(options.cursor!))
      : sorted;
    return all.slice(0, limit);
  }

  /** Withdrawals require KYC + name-matched payout account (server-enforced). */
  async requestWithdrawal(
    amount: Money,
    idempotencyKey: string,
  ): Promise<WalletTransaction> {
    await this.gate();
    return this.idempotent(
      'walletWithdrawal',
      idempotencyKey,
      `${amount.amountMinor} ${amount.currency}`,
      async () => {
        const summary = await this.getSummary();
        const pack = this.db.countryPacks[this.currentUser.countryCode];
        const min = pack?.minWithdrawal;
        if (
          min &&
          min.currency === amount.currency &&
          amount.amountMinor < min.amountMinor
        ) {
          throw new AppError(ErrorCodes.withdrawalBelowMinimum);
        }
        if (amount.amountMinor > summary.available.amountMinor) {
          throw new AppError(ErrorCodes.insufficientBalance);
        }
        // Finance-approval threshold, per currency (like the backend's
        // per-country rule — not a hard-coded USD check). Above it the
        // withdrawal still SUCCEEDS with an awaiting-approval status
        // (contracts: withdrawal_status = 'awaiting_approval') — it is not
        // an error.
        const threshold = this.behavior.withdrawalApprovalThresholds[amount.currency];
        const status: WalletTransactionStatus =
          threshold !== undefined && amount.amountMinor > threshold
            ? 'awaiting_approval'
            : 'pending';
        const txn: WalletTransaction = {
          id: `txn-${Date.now()}`,
          kind: 'payout',
          status,
          amount,
          descriptionKey: 'txnWithdrawal',
          createdAt: this.now(),
        };
        (this.db.walletTransactions[this.currentUser.id] ??= []).push(txn);
        return txn;
      },
    );
  }
}

export class MockReferralRepository extends MockRepo {
  constructor(db: MockDatabase, behavior: MockBehavior) {
    super(db, behavior);
  }

  private currency(): string {
    return this.db.countryPacks[this.currentUser.countryCode]?.currencyCode ?? 'NGN';
  }

  async getSummary(): Promise<ReferralSummary> {
    await this.gate();
    const currency = this.currency();
    return (
      this.db.referrals[this.currentUser.id] ?? {
        code: 'NEW-USER',
        shareLink: 'https://suskii.app/r/NEW-USER',
        invitedCount: 0,
        activeReferrals: 0,
        earnedTotal: { amountMinor: 0, currency },
        holding: { amountMinor: 0, currency },
        available: { amountMinor: 0, currency },
      }
    );
  }

  async requestWithdrawal(
    amount: Money,
    idempotencyKey: string,
  ): Promise<WalletTransaction> {
    await this.gate();
    return this.idempotent(
      'referralWithdrawal',
      idempotencyKey,
      `${amount.amountMinor} ${amount.currency}`,
      async () => {
        const summary = await this.getSummary();
        if (amount.amountMinor > summary.available.amountMinor) {
          throw new AppError(ErrorCodes.insufficientBalance);
        }
        return {
          id: `txn-ref-${Date.now()}`,
          kind: 'referral',
          status: 'pending',
          amount,
          descriptionKey: 'txnReferralWithdrawal',
          createdAt: this.now(),
        } satisfies WalletTransaction;
      },
    );
  }
}

export class MockPromoRepository extends MockRepo {
  async getPromos(): Promise<Promo[]> {
    await this.gate();
    return Object.values(this.db.promos);
  }

  /**
   * Redemption validity is a server decision — unknown, expired or
   * already-redeemed codes all get the single ERR_PROMO_INVALID verdict.
   */
  async redeemPromo(code: string, idempotencyKey: string): Promise<Promo> {
    await this.gate();
    const normalized = code.trim().toUpperCase();
    return this.idempotent('redeemPromo', idempotencyKey, normalized, () => {
      const promo = this.db.promos[normalized];
      if (
        !promo ||
        promo.redeemed ||
        promo.expiresAt.getTime() < this.now().getTime()
      ) {
        throw new AppError(ErrorCodes.promoInvalid);
      }
      const redeemed: Promo = { ...promo, redeemed: true };
      this.db.promos[normalized] = redeemed;
      return redeemed;
    });
  }
}

/** States in which a party can still open a dispute. */
const DISPUTABLE: ReadonlySet<JobStatus> = new Set([
  'paid_held',
  'assigned',
  'en_route',
  'arrived',
  'in_progress',
  'completed_by_provider',
  'confirmed',
]);

export class MockDisputeRepository extends MockRepo {
  constructor(db: MockDatabase, behavior: MockBehavior) {
    super(db, behavior);
  }

  async getMyDisputes(): Promise<Dispute[]> {
    await this.gate();
    const user = this.currentUser;
    return Object.values(this.db.disputes)
      .filter((d) => {
        const job = this.db.requests[d.jobId];
        return (
          d.openedBy === user.id ||
          job?.customerId === user.id ||
          job?.providerId === user.id
        );
      })
      .sort((a, b) => b.createdAt.getTime() - a.createdAt.getTime());
  }

  /** Emits the job's dispute (or undefined) immediately, then changes. */
  watchDispute(jobId: string, onChange: (dispute: Dispute | undefined) => void): Unsubscribe {
    onChange(this.db.disputes[jobId]);
    return this.db.disputeEvents.subscribe((d) => {
      if (d.jobId === jobId) onChange(d);
    });
  }

  /**
   * Opening a dispute is an action request — the server freezes the payout,
   * starts the SLA clock and moves the job to DISPUTED. One dispute per
   * job: re-opening returns the existing one.
   */
  async openDispute(options: {
    jobId: string;
    reasonKey: string;
    idempotencyKey: string;
    details?: string;
    evidencePaths?: string[];
  }): Promise<Dispute> {
    await this.gate();
    const { jobId, reasonKey, idempotencyKey, details, evidencePaths = [] } = options;
    return this.idempotent(
      `openDispute:${jobId}`,
      idempotencyKey,
      `${reasonKey}|${details ?? ''}|${evidencePaths.join(',')}`,
      () => {
        const user = this.currentUser;
        const job = this.db.requests[jobId];
        if (!job) throw new AppError(ErrorCodes.unknown);
        if (job.customerId !== user.id && job.providerId !== user.id) {
          throw new AppError(ErrorCodes.permissionDenied);
        }
        const existing = this.db.disputes[jobId];
        if (existing) return existing;
        if (!DISPUTABLE.has(job.status)) {
          throw new AppError(ErrorCodes.invalidState);
        }
        const dispute: Dispute = {
          id: `disp-${Date.now()}`,
          jobId,
          openedBy: user.id,
          reasonKey,
          status: 'open',
          createdAt: this.now(),
          details,
          evidencePaths: evidencePaths.length > 0 ? evidencePaths : undefined,
          slaDeadline: new Date(this.now().getTime() + 24 * 3_600_000),
        };
        this.store(dispute);
        const disputed: typeof job = { ...job, status: 'disputed' };
        this.db.requests[jobId] = disputed;
        this.db.jobEvents.emit(disputed);
        this.scheduleResolution(dispute.id);
        return dispute;
      },
    );
  }

  /**
   * The mock "ops team": after `disputeResolveDelayMs` the dispute resolves
   * with a 50% partial refund — job → REFUNDED, payment →
   * PARTIALLY_REFUNDED. All amounts are server-decided.
   */
  private scheduleResolution(disputeId: string): void {
    setTimeout(() => {
      const current = Object.values(this.db.disputes).find((d) => d.id === disputeId);
      if (!current || current.status === 'resolved') return;
      const job = this.db.requests[current.jobId];
      const agreed = job?.agreedPrice;
      const refund: Money | undefined = agreed
        ? {
            amountMinor: Math.floor(agreed.amountMinor / 2),
            currency: agreed.currency,
          }
        : undefined;
      this.store({
        ...current,
        status: 'resolved',
        resolutionNoteKey: 'disputeResolvedPartialRefund',
        refundAmount: refund,
      });
      if (job) {
        const refunded = { ...job, status: 'refunded' as JobStatus };
        this.db.requests[job.id] = refunded;
        this.db.jobEvents.emit(refunded);
      }
      const paymentId = this.db.paymentByJob[current.jobId];
      const payment = paymentId ? this.db.payments[paymentId] : undefined;
      if (payment && payment.status === 'held') {
        const refunded = { ...payment, status: 'partially_refunded' as const };
        this.db.payments[payment.id] = refunded;
        this.db.paymentEvents.emit(refunded);
      }
    }, this.behavior.disputeResolveDelayMs);
  }

  private store(dispute: Dispute): void {
    this.db.disputes[dispute.jobId] = dispute;
    this.db.disputeEvents.emit(dispute);
  }
}

export class MockSupportRepository extends MockRepo {
  constructor(db: MockDatabase, behavior: MockBehavior) {
    super(db, behavior);
  }

  private sorted(): SupportTicket[] {
    return Object.values(this.db.tickets).sort(
      (a, b) => b.createdAt.getTime() - a.createdAt.getTime(),
    );
  }

  async getTickets(): Promise<SupportTicket[]> {
    await this.gate();
    return this.sorted();
  }

  /** Emits the sorted ticket list immediately, then on every change. */
  watchTickets(onChange: (tickets: SupportTicket[]) => void): Unsubscribe {
    onChange(this.sorted());
    return this.db.supportEvents.subscribe(() => onChange(this.sorted()));
  }

  async createTicket(options: {
    subject: string;
    body: string;
    idempotencyKey: string;
  }): Promise<SupportTicket> {
    await this.gate();
    const { subject, body, idempotencyKey } = options;
    return this.idempotent('createTicket', idempotencyKey, `${subject}|${body}`, () => {
      const now = this.now();
      const ticket: SupportTicket = {
        id: `ticket-${Date.now()}`,
        subject,
        status: 'open',
        createdAt: now,
        messages: [
          {
            id: `tmsg-${now.getTime()}`,
            body,
            fromUser: true,
            aiTriage: false,
            createdAt: now,
          },
        ],
      };
      this.db.tickets[ticket.id] = ticket;
      this.db.supportEvents.emit(ticket);
      this.scheduleTriageReply(ticket.id);
      return ticket;
    });
  }

  async replyToTicket(
    ticketId: string,
    body: string,
    idempotencyKey: string,
  ): Promise<SupportTicket> {
    await this.gate();
    return this.idempotent(`replyTicket:${ticketId}`, idempotencyKey, body, () => {
      const ticket = this.db.tickets[ticketId];
      if (!ticket) throw new AppError(ErrorCodes.unknown);
      if (ticket.status === 'closed' || ticket.status === 'resolved') {
        throw new AppError(ErrorCodes.invalidState);
      }
      const message = {
        id: `tmsg-${Date.now()}`,
        body,
        fromUser: true,
        aiTriage: false,
        createdAt: this.now(),
      };
      const updated: SupportTicket = {
        ...ticket,
        status: 'open',
        messages: [...ticket.messages, message],
      };
      this.db.tickets[ticketId] = updated;
      this.db.supportEvents.emit(updated);
      this.scheduleTriageReply(ticketId);
      return updated;
    });
  }

  /** AI first-line triage replies after a delay (human handoff is server-side). */
  private scheduleTriageReply(ticketId: string): void {
    setTimeout(() => {
      const ticket = this.db.tickets[ticketId];
      if (!ticket || ticket.status !== 'open') return;
      const reply = {
        id: `tmsg-ai-${Date.now()}`,
        body:
          'Thanks for the details — I have logged this and flagged it for ' +
          'our support team. You will hear from a human agent shortly.',
        fromUser: false,
        aiTriage: true,
        createdAt: this.now(),
      };
      const updated: SupportTicket = {
        ...ticket,
        status: 'awaiting_user',
        messages: [...ticket.messages, reply],
      };
      this.db.tickets[ticketId] = updated;
      this.db.supportEvents.emit(updated);
    }, this.behavior.supportTriageDelayMs);
  }
}

const MAX_TRUSTED_CONTACTS = 5;
const ACCOUNT_DELETION_GRACE_MS = 30 * 86_400_000;

export class MockSettingsRepository extends MockRepo {
  constructor(db: MockDatabase, behavior: MockBehavior) {
    super(db, behavior);
  }

  private defaultPrefs(): NotificationPreferences {
    return { push: true, sms: true, email: true, marketing: false };
  }

  async getNotificationPreferences(): Promise<NotificationPreferences> {
    await this.gate();
    return this.db.notificationPrefs[this.currentUser.id] ?? this.defaultPrefs();
  }

  async updateNotificationPreferences(
    preferences: NotificationPreferences,
    idempotencyKey: string,
  ): Promise<NotificationPreferences> {
    await this.gate();
    return this.idempotent(
      'updateNotificationPreferences',
      idempotencyKey,
      JSON.stringify(preferences),
      () => {
        this.db.notificationPrefs[this.currentUser.id] = preferences;
        return preferences;
      },
    );
  }

  async getTrustedContacts(): Promise<TrustedContact[]> {
    await this.gate();
    return [...(this.db.trustedContacts[this.currentUser.id] ?? [])];
  }

  /** Up to 5 contacts; the 6th throws ERR_INVALID_STATE. */
  async addTrustedContact(options: {
    name: string;
    phoneE164: string;
    idempotencyKey: string;
  }): Promise<TrustedContact> {
    await this.gate();
    const { name, phoneE164, idempotencyKey } = options;
    return this.idempotent(
      'addTrustedContact',
      idempotencyKey,
      `${name}|${phoneE164}`,
      () => {
        const list = (this.db.trustedContacts[this.currentUser.id] ??= []);
        if (list.length >= MAX_TRUSTED_CONTACTS) {
          throw new AppError(ErrorCodes.invalidState);
        }
        const contact: TrustedContact = {
          id: `tc-${Date.now()}`,
          name,
          phoneE164,
        };
        list.push(contact);
        return contact;
      },
    );
  }

  async removeTrustedContact(contactId: string, idempotencyKey: string): Promise<void> {
    await this.gate();
    return this.idempotent(`removeTrustedContact:${contactId}`, idempotencyKey, '', () => {
      const userId = this.currentUser.id;
      this.db.trustedContacts[userId] = (this.db.trustedContacts[userId] ?? []).filter(
        (c) => c.id !== contactId,
      );
    });
  }

  /**
   * In-app account deletion with a grace period (spec: store_readiness).
   * Returns the scheduled deletion date; signing back in before it cancels.
   */
  async requestAccountDeletion(idempotencyKey: string): Promise<Date> {
    await this.gate();
    return this.idempotent('requestAccountDeletion', idempotencyKey, '', () => {
      return new Date(this.now().getTime() + ACCOUNT_DELETION_GRACE_MS);
    });
  }

  /** GDPR-style data export. Returns an opaque export reference. */
  async requestDataExport(idempotencyKey: string): Promise<string> {
    await this.gate();
    return this.idempotent('requestDataExport', idempotencyKey, '', () => {
      return `export-${this.currentUser.id}-${Date.now()}`;
    });
  }
}
