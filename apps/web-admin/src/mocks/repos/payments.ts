// Payments repository: holds / settlements / payouts / withdrawals with
// single-approval and two-person approval flows. All amounts arrive as
// server-style quote objects — the console never derives them. Approval
// actions are sensitive (reauth within 5 min) and finance-gated.

import { AppError, ErrorCodes } from '../errors';
import type { PaymentAdminKind, PaymentAdminStatus, PaymentAdminView } from '../types';
import { MockRepo } from './base';

export interface PaymentFilter {
  kind?: PaymentAdminKind;
  status?: PaymentAdminStatus;
  country?: string;
}

export class MockPaymentsRepository extends MockRepo {
  async listPayments(filter?: PaymentFilter): Promise<PaymentAdminView[]> {
    await this.gate();
    this.requirePermission('payments.read');
    return Object.values(this.db.payments).filter((p) => {
      if (filter?.kind && p.kind !== filter.kind) return false;
      if (filter?.status && p.status !== filter.status) return false;
      if (filter?.country && p.country !== filter.country) return false;
      return true;
    });
  }

  async getPayment(paymentId: string): Promise<PaymentAdminView> {
    await this.gate();
    this.requirePermission('payments.read');
    const payment = this.db.payments[paymentId];
    if (!payment) throw new AppError(ErrorCodes.unknown);
    return payment;
  }

  /**
   * Single-approval withdrawal (below the two-person threshold): one
   * finance approval moves it to processing. Withdrawals at or above
   * mockBehavior.twoPersonApprovalThresholds are refused with
   * ERR_APPROVAL_REQUIRED — the UI then drives requestApproval →
   * confirmApproval instead.
   */
  async approveWithdrawal(
    paymentId: string,
    idempotencyKey: string,
  ): Promise<PaymentAdminView> {
    await this.gate();
    const admin = this.requireSensitive('payments.approve');
    return this.idempotent(`payments.approve:${paymentId}`, idempotencyKey, '', () => {
      const payment = this.requirePendingWithdrawal(paymentId);
      if (payment.approval.state !== 'single_pending') {
        throw new AppError(ErrorCodes.approvalRequired);
      }
      const threshold =
        this.behavior.twoPersonApprovalThresholds[payment.quote.gross.currency];
      if (
        threshold !== undefined &&
        payment.quote.gross.amountMinor >= threshold
      ) {
        throw new AppError(ErrorCodes.approvalRequired, {
          details: 'amount requires the two-person flow — call requestApproval',
        });
      }
      payment.approval = {
        state: 'approved',
        approverIds: [admin.id],
        requestedAt: payment.approval.requestedAt,
        decidedAt: this.now(),
      };
      payment.status = 'processing';
      this.audit('payments.approve_withdrawal', `payment/${paymentId}`);
      return payment;
    });
  }

  /**
   * Two-person flow, step 1: first approver requests approval. The payment
   * moves to awaiting_second and a DIFFERENT admin must confirm.
   */
  async requestApproval(
    paymentId: string,
    idempotencyKey: string,
  ): Promise<PaymentAdminView> {
    await this.gate();
    const admin = this.requireSensitive('payments.approve');
    return this.idempotent(`payments.request:${paymentId}`, idempotencyKey, '', () => {
      const payment = this.requirePendingWithdrawal(paymentId);
      if (payment.approval.state !== 'single_pending') {
        throw new AppError(ErrorCodes.invalidState);
      }
      payment.approval.state = 'awaiting_second';
      payment.approval.approverIds = [admin.id];
      payment.approval.requestedAt = this.now();
      this.audit('payments.request_approval', `payment/${paymentId}`);
      return payment;
    });
  }

  /**
   * Two-person flow, step 2: a second, distinct approver confirms. The same
   * admin confirming their own request is refused with ERR_INVALID_STATE.
   */
  async confirmApproval(
    paymentId: string,
    idempotencyKey: string,
  ): Promise<PaymentAdminView> {
    await this.gate();
    const admin = this.requireSensitive('payments.approve');
    return this.idempotent(`payments.confirm:${paymentId}`, idempotencyKey, '', () => {
      const payment = this.requirePendingWithdrawal(paymentId);
      if (payment.approval.state !== 'awaiting_second') {
        throw new AppError(ErrorCodes.invalidState);
      }
      if (payment.approval.approverIds.includes(admin.id)) {
        throw new AppError(ErrorCodes.invalidState, {
          details: 'second approver must differ from the first',
        });
      }
      payment.approval.approverIds = [...payment.approval.approverIds, admin.id];
      payment.approval.state = 'approved';
      payment.approval.decidedAt = this.now();
      payment.status = 'processing';
      this.audit('payments.confirm_approval', `payment/${paymentId}`);
      return payment;
    });
  }

  /** Reject a pending approval (single or two-person) with a reason. */
  async rejectApproval(
    paymentId: string,
    reason: string,
    idempotencyKey: string,
  ): Promise<PaymentAdminView> {
    await this.gate();
    const admin = this.requireSensitive('payments.approve');
    return this.idempotent(`payments.reject:${paymentId}`, idempotencyKey, reason, () => {
      const payment = this.requirePendingWithdrawal(paymentId);
      const { state } = payment.approval;
      if (state !== 'single_pending' && state !== 'awaiting_second') {
        throw new AppError(ErrorCodes.invalidState);
      }
      payment.approval.state = 'rejected';
      payment.approval.rejectedByAdminId = admin.id;
      payment.approval.decidedAt = this.now();
      payment.status = 'failed';
      this.audit('payments.reject_approval', `payment/${paymentId}`, reason);
      return payment;
    });
  }

  private requirePendingWithdrawal(paymentId: string): PaymentAdminView {
    const payment = this.db.payments[paymentId];
    if (!payment) throw new AppError(ErrorCodes.unknown);
    if (payment.kind !== 'withdrawal' || payment.status !== 'pending') {
      throw new AppError(ErrorCodes.invalidState);
    }
    return payment;
  }
}
