// Money as the console sees it: customer payments (held funds), payouts to providers
// and withdrawals waiting for finance. Withdrawals are approved through
// approve_withdrawal, whose four eyes live in `approvals`: the country pack decides
// whether one signature or two, and the second must be a different person.

import { AppError, ErrorCodes } from '@/mocks/errors';
import type { PaymentFilter } from '@/mocks/repositories';
import type {
  ApprovalRecord,
  PaymentAdminStatus,
  PaymentAdminView,
} from '@/mocks/types';

import { SupabaseAdminRepo, money } from './base';
import { SupabaseGateway, type Row } from './gateway';

const PAYMENT_STATUS: Record<string, PaymentAdminStatus> = {
  unpaid: 'pending',
  pending: 'pending',
  held: 'held',
  failed: 'failed',
  refunded: 'refunded',
  partially_refunded: 'refunded',
};

const PAYOUT_STATUS: Record<string, PaymentAdminStatus> = {
  requested: 'processing',
  submitted: 'processing',
  pending: 'processing',
  succeeded: 'completed',
  failed: 'failed',
  reversed: 'failed',
};

const WITHDRAWAL_STATUS: Record<string, PaymentAdminStatus> = {
  requested: 'pending',
  awaiting_approval: 'pending',
  approved: 'processing',
  processing: 'processing',
  paid: 'completed',
  rejected: 'failed',
  failed: 'failed',
};

export class SupabasePaymentsRepository extends SupabaseAdminRepo {
  async listPayments(filter?: PaymentFilter): Promise<PaymentAdminView[]> {
    const [payments, payouts, withdrawals] = await Promise.all([
      filter?.kind && filter.kind !== 'hold' && filter.kind !== 'settlement'
        ? Promise.resolve([])
        : this.gw.selectList(
            'payments',
            'id, request_id, payer_id, amount_minor, currency, status, fee_minor, created_at',
            { orderBy: 'created_at', ascending: false, limit: 200 },
          ),
      filter?.kind && filter.kind !== 'payout'
        ? Promise.resolve([])
        : this.gw.selectList(
            'payouts',
            'id, beneficiary_id, amount_minor, fee_minor, currency, status, created_at',
            { orderBy: 'created_at', ascending: false, limit: 200 },
          ),
      filter?.kind && filter.kind !== 'withdrawal'
        ? Promise.resolve([])
        : this.gw.selectList(
            'withdrawals',
            'id, user_id, amount_minor, currency, status, approvals_required, created_at, decided_at',
            { orderBy: 'created_at', ascending: false, limit: 200 },
          ),
    ]);

    const people = [
      ...payments.map((p) => p['payer_id']),
      ...payouts.map((p) => p['beneficiary_id']),
      ...withdrawals.map((w) => w['user_id']),
    ];
    const profiles = await this.gw.selectList('profiles', 'user_id, display_name, country_code', {
      inColumn: 'user_id',
      inValues: [...new Set(people.map(String))],
    });
    const profileOf = new Map(profiles.map((p) => [String(p['user_id']), p]));
    const approvals = await this.gw.selectList(
      'approvals',
      'subject_id, approved_by, status, level, created_at, decided_at',
      { column: 'subject_kind', value: 'withdrawal', orderBy: 'level' },
    );

    const views: PaymentAdminView[] = [
      ...payments.map((p) => this.paymentView(p, profileOf.get(String(p['payer_id'])))),
      ...payouts.map((p) => this.payoutView(p, profileOf.get(String(p['beneficiary_id'])))),
      ...withdrawals.map((w) =>
        this.withdrawalView(
          w,
          profileOf.get(String(w['user_id'])),
          approvals.filter((a) => String(a['subject_id']) === String(w['id'])),
        ),
      ),
    ];
    return views
      .filter((v) => {
        if (filter?.kind && v.kind !== filter.kind) return false;
        if (filter?.status && v.status !== filter.status) return false;
        if (filter?.country && v.country !== filter.country) return false;
        return true;
      })
      .sort((a, b) => b.createdAt.getTime() - a.createdAt.getTime());
  }

  async getPayment(paymentId: string): Promise<PaymentAdminView> {
    const view = (await this.listPayments()).find((p) => p.id === paymentId);
    if (!view) throw new AppError(ErrorCodes.notFound);
    return view;
  }

  /**
   * One signature. When the country pack wants two, the console is told so and asks for
   * the first of two instead (the same call on the server; the copy differs).
   */
  async approveWithdrawal(paymentId: string, idempotencyKey: string): Promise<PaymentAdminView> {
    await this.requireRecentMfa('payments.approve');
    const current = await this.getPayment(paymentId);
    if (current.approval.state === 'single_pending' && (current.approvalsRequired ?? 1) > 1) {
      throw new AppError(ErrorCodes.approvalRequired);
    }
    return this.sign(paymentId, idempotencyKey, true);
  }

  async requestApproval(paymentId: string, idempotencyKey: string): Promise<PaymentAdminView> {
    await this.requireRecentMfa('payments.approve');
    return this.sign(paymentId, idempotencyKey, true);
  }

  async confirmApproval(paymentId: string, idempotencyKey: string): Promise<PaymentAdminView> {
    await this.requireRecentMfa('payments.approve');
    return this.sign(paymentId, idempotencyKey, true);
  }

  async rejectApproval(
    paymentId: string,
    reason: string,
    idempotencyKey: string,
  ): Promise<PaymentAdminView> {
    await this.requireRecentMfa('payments.approve');
    return this.sign(paymentId, idempotencyKey, false, reason);
  }

  private async sign(
    withdrawalId: string,
    idempotencyKey: string,
    approve: boolean,
    reasonKey?: string,
  ): Promise<PaymentAdminView> {
    await this.gw.rpc('approve_withdrawal', {
      p_idempotency_key: idempotencyKey,
      p_withdrawal_id: withdrawalId,
      p_approve: approve,
      p_reason_key: reasonKey,
    });
    return this.getPayment(withdrawalId);
  }

  private paymentView(row: Row, profile: Row | undefined): PaymentAdminView {
    const gross = money(row['amount_minor'], row['currency']);
    const fee = SupabaseGateway.asMinorUnits(row['fee_minor'] ?? 0);
    return {
      id: String(row['id']),
      kind: 'hold',
      country: String(profile?.['country_code'] ?? ''),
      referenceId: String(row['request_id']),
      counterpartyName: String(profile?.['display_name'] ?? '—'),
      quote: { gross, net: { amountMinor: gross.amountMinor - fee, currency: gross.currency } },
      status: PAYMENT_STATUS[String(row['status'])] ?? 'pending',
      approval: { state: 'none', approverIds: [] },
      createdAt: SupabaseGateway.asTimestamp(row['created_at']),
    };
  }

  private payoutView(row: Row, profile: Row | undefined): PaymentAdminView {
    const gross = money(row['amount_minor'], row['currency']);
    const fee = SupabaseGateway.asMinorUnits(row['fee_minor'] ?? 0);
    return {
      id: String(row['id']),
      kind: 'payout',
      country: String(profile?.['country_code'] ?? ''),
      referenceId: String(row['beneficiary_id']),
      counterpartyName: String(profile?.['display_name'] ?? '—'),
      quote: { gross, net: { amountMinor: gross.amountMinor - fee, currency: gross.currency } },
      status: PAYOUT_STATUS[String(row['status'])] ?? 'processing',
      approval: { state: 'none', approverIds: [] },
      createdAt: SupabaseGateway.asTimestamp(row['created_at']),
    };
  }

  private withdrawalView(row: Row, profile: Row | undefined, approvals: Row[]): PaymentAdminView {
    const amount = money(row['amount_minor'], row['currency']);
    return {
      id: String(row['id']),
      kind: 'withdrawal',
      country: String(profile?.['country_code'] ?? ''),
      referenceId: String(row['user_id']),
      counterpartyName: String(profile?.['display_name'] ?? '—'),
      quote: { gross: amount, net: amount },
      status: WITHDRAWAL_STATUS[String(row['status'])] ?? 'pending',
      approval: this.approval(row, approvals),
      approvalsRequired: Number(row['approvals_required'] ?? 1),
      createdAt: SupabaseGateway.asTimestamp(row['created_at']),
    };
  }

  private approval(row: Row, approvals: Row[]): ApprovalRecord {
    const signed = approvals.filter((a) => a['status'] === 'approved');
    const rejected = approvals.find((a) => a['status'] === 'rejected');
    const base = {
      approverIds: signed.map((a) => String(a['approved_by'])),
      requestedAt: approvals[0] ? SupabaseGateway.asTimestamp(approvals[0]['created_at']) : undefined,
      decidedAt: SupabaseGateway.asOptionalTimestamp(row['decided_at']),
    };
    switch (row['status']) {
      case 'awaiting_approval':
      case 'requested':
        return { ...base, state: signed.length === 0 ? 'single_pending' : 'awaiting_second' };
      case 'approved':
      case 'processing':
      case 'paid':
        return { ...base, state: 'approved' };
      case 'rejected':
        return {
          ...base,
          state: 'rejected',
          rejectedByAdminId: rejected ? String(rejected['approved_by']) : undefined,
        };
      default:
        return { ...base, state: 'none' };
    }
  }
}
