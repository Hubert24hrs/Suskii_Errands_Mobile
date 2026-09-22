// Trust & safety repositories: disputes (server-computed resolution quotes),
// support tickets, the SOS operations console (live trail ticker), and
// risk/fraud cases.

import { roundHalfEven } from '../behavior';
import { AppError, ErrorCodes } from '../errors';
import type {
  DisputeCase,
  DisputeCaseStatus,
  DisputeResolutionAction,
  DisputeResolutionQuote,
  RiskCase,
  SosAlertAdmin,
  SupportTicketAdmin,
} from '../types';
import { MockRepo, type Unsubscribe } from './base';

export class MockDisputeRepository extends MockRepo {
  async listDisputes(status?: DisputeCaseStatus): Promise<DisputeCase[]> {
    await this.gate();
    this.requirePermission('disputes.read');
    return Object.values(this.db.disputes).filter((d) => !status || d.status === status);
  }

  async getDispute(disputeId: string): Promise<DisputeCase> {
    await this.gate();
    this.requirePermission('disputes.read');
    const dispute = this.db.disputes[disputeId];
    if (!dispute) throw new AppError(ErrorCodes.unknown);
    return dispute;
  }

  /** Take ownership of a dispute (open → in_review, assigned to self). */
  async assignDispute(disputeId: string, idempotencyKey: string): Promise<DisputeCase> {
    await this.gate();
    const admin = this.requirePermission('disputes.resolve');
    return this.idempotent(`disputes.assign:${disputeId}`, idempotencyKey, '', () => {
      const dispute = this.db.disputes[disputeId];
      if (!dispute) throw new AppError(ErrorCodes.unknown);
      if (dispute.status !== 'open') throw new AppError(ErrorCodes.invalidState);
      dispute.status = 'in_review';
      dispute.assignedToAdminId = admin.id;
      this.audit('disputes.assign', `dispute/${disputeId}`);
      return dispute;
    });
  }

  /**
   * Server-computed resolution quote: the admin chooses an action (and, for
   * refund_partial, a percentage) — the exact amounts come back from the
   * server, never derived client-side.
   */
  async getResolutionQuote(
    disputeId: string,
    action: DisputeResolutionAction,
    partialPercent?: number,
  ): Promise<DisputeResolutionQuote> {
    await this.gate();
    this.requirePermission('disputes.read');
    const dispute = this.db.disputes[disputeId];
    if (!dispute) throw new AppError(ErrorCodes.unknown);
    return this.computeResolutionQuote(dispute, action, partialPercent);
  }

  /**
   * Resolve a dispute. Sensitive (reauth within 5 min) and restricted to
   * dispute officers / super admins. Applies the server-computed amounts to
   * the job and writes the resolution onto the case.
   */
  async resolveDispute(
    disputeId: string,
    action: DisputeResolutionAction,
    options: { partialPercent?: number; note?: string },
    idempotencyKey: string,
  ): Promise<DisputeCase> {
    await this.gate();
    const admin = this.requireSensitive('disputes.resolve');
    return this.idempotent(
      `disputes.resolve:${disputeId}`,
      idempotencyKey,
      `${action}:${options.partialPercent ?? ''}`,
      () => {
        const dispute = this.db.disputes[disputeId];
        if (!dispute) throw new AppError(ErrorCodes.unknown);
        if (dispute.status !== 'open' && dispute.status !== 'in_review') {
          throw new AppError(ErrorCodes.alreadyReviewed);
        }
        const quote = this.computeResolutionQuote(dispute, action, options.partialPercent);
        dispute.status = action === 'reject' ? 'rejected' : 'resolved';
        dispute.resolution = {
          action,
          quote,
          byAdminId: admin.id,
          at: this.now(),
        };
        const job = this.db.jobs[dispute.jobId];
        if (job) {
          job.status =
            action === 'refund_full' || action === 'refund_partial'
              ? 'refunded'
              : 'confirmed';
        }
        this.audit(
          `disputes.resolve_${action}`,
          `dispute/${disputeId}`,
          options.note ??
            `refund ${quote.refundToCustomer.amountMinor} / release ${quote.releaseToProvider.amountMinor} ${quote.refundToCustomer.currency}`,
        );
        return dispute;
      },
    );
  }

  private computeResolutionQuote(
    dispute: DisputeCase,
    action: DisputeResolutionAction,
    partialPercent?: number,
  ): DisputeResolutionQuote {
    const held = dispute.heldAmount;
    const zero = { amountMinor: 0, currency: held.currency };
    switch (action) {
      case 'refund_full':
        return { action, refundToCustomer: held, releaseToProvider: zero, platformRetained: zero };
      case 'refund_partial': {
        const pct = partialPercent ?? 50;
        if (pct <= 0 || pct >= 100) throw new AppError(ErrorCodes.invalidState);
        const refund = {
          amountMinor: roundHalfEven(held.amountMinor * pct, 100),
          currency: held.currency,
        };
        return {
          action,
          refundToCustomer: refund,
          releaseToProvider: {
            amountMinor: held.amountMinor - refund.amountMinor,
            currency: held.currency,
          },
          platformRetained: zero,
        };
      }
      case 'release_to_provider':
        return { action, refundToCustomer: zero, releaseToProvider: held, platformRetained: zero };
      case 'reject':
        return { action, refundToCustomer: zero, releaseToProvider: zero, platformRetained: zero };
    }
  }
}

export class MockSupportRepository extends MockRepo {
  async listTickets(status?: SupportTicketAdmin['status']): Promise<SupportTicketAdmin[]> {
    await this.gate();
    this.requirePermission('support.read');
    return Object.values(this.db.tickets).filter((t) => !status || t.status === status);
  }

  async getTicket(ticketId: string): Promise<SupportTicketAdmin> {
    await this.gate();
    this.requirePermission('support.read');
    const ticket = this.db.tickets[ticketId];
    if (!ticket) throw new AppError(ErrorCodes.unknown);
    return ticket;
  }

  async assignTicket(ticketId: string, idempotencyKey: string): Promise<SupportTicketAdmin> {
    await this.gate();
    const admin = this.requirePermission('support.manage');
    return this.idempotent(`support.assign:${ticketId}`, idempotencyKey, '', () => {
      const ticket = this.db.tickets[ticketId];
      if (!ticket) throw new AppError(ErrorCodes.unknown);
      if (ticket.status === 'closed') throw new AppError(ErrorCodes.invalidState);
      ticket.status = 'assigned';
      ticket.assignedToAdminId = admin.id;
      this.audit('support.assign', `ticket/${ticketId}`);
      return ticket;
    });
  }

  async replyTicket(
    ticketId: string,
    body: string,
    idempotencyKey: string,
  ): Promise<SupportTicketAdmin> {
    await this.gate();
    this.requirePermission('support.manage');
    return this.idempotent(`support.reply:${ticketId}`, idempotencyKey, body, () => {
      const ticket = this.db.tickets[ticketId];
      if (!ticket) throw new AppError(ErrorCodes.unknown);
      if (ticket.status === 'closed') throw new AppError(ErrorCodes.invalidState);
      ticket.messages.push({
        id: `stm-${ticket.messages.length + 1}-${Date.now()}`,
        author: 'agent',
        body,
        at: this.now(),
      });
      this.audit('support.reply', `ticket/${ticketId}`);
      return ticket;
    });
  }

  async closeTicket(ticketId: string, idempotencyKey: string): Promise<SupportTicketAdmin> {
    await this.gate();
    this.requirePermission('support.manage');
    return this.idempotent(`support.close:${ticketId}`, idempotencyKey, '', () => {
      const ticket = this.db.tickets[ticketId];
      if (!ticket) throw new AppError(ErrorCodes.unknown);
      if (ticket.status === 'closed') throw new AppError(ErrorCodes.invalidState);
      ticket.status = 'closed';
      this.audit('support.close', `ticket/${ticketId}`);
      return ticket;
    });
  }
}

export class MockSosRepository extends MockRepo {
  private ticker: ReturnType<typeof setInterval> | null = null;
  private watcherCount = 0;

  async listAlerts(status?: SosAlertAdmin['status']): Promise<SosAlertAdmin[]> {
    await this.gate();
    this.requirePermission('sos.read');
    return Object.values(this.db.sosAlerts).filter((a) => !status || a.status === status);
  }

  async getAlert(alertId: string): Promise<SosAlertAdmin> {
    await this.gate();
    this.requirePermission('sos.read');
    const alert = this.db.sosAlerts[alertId];
    if (!alert) throw new AppError(ErrorCodes.unknown);
    return alert;
  }

  /**
   * Real-time operations feed: emits every SOS alert update. While at least
   * one watcher is attached, active alerts keep accruing location pings
   * (every mockBehavior.sosTickIntervalMs) — the console map trails live.
   */
  watchAlerts(listener: (alert: SosAlertAdmin) => void): Unsubscribe {
    this.requirePermission('sos.read');
    this.startTicker();
    const unsubscribe = this.db.sosEvents.subscribe(listener);
    return () => {
      unsubscribe();
      this.stopTicker();
    };
  }

  async acknowledge(alertId: string, idempotencyKey: string): Promise<SosAlertAdmin> {
    await this.gate();
    const admin = this.requirePermission('sos.manage');
    return this.idempotent(`sos.acknowledge:${alertId}`, idempotencyKey, '', () => {
      const alert = this.db.sosAlerts[alertId];
      if (!alert) throw new AppError(ErrorCodes.unknown);
      if (alert.status !== 'active') throw new AppError(ErrorCodes.invalidState);
      alert.status = 'acknowledged';
      alert.acknowledgedByAdminId = admin.id;
      alert.acknowledgedAt = this.now();
      this.audit('sos.acknowledge', `sos/${alertId}`);
      this.db.sosEvents.emit(alert);
      return alert;
    });
  }

  async resolve(
    alertId: string,
    note: string,
    idempotencyKey: string,
  ): Promise<SosAlertAdmin> {
    await this.gate();
    this.requirePermission('sos.manage');
    return this.idempotent(`sos.resolve:${alertId}`, idempotencyKey, note, () => {
      const alert = this.db.sosAlerts[alertId];
      if (!alert) throw new AppError(ErrorCodes.unknown);
      if (alert.status === 'resolved') throw new AppError(ErrorCodes.invalidState);
      alert.status = 'resolved';
      alert.resolvedAt = this.now();
      alert.resolutionNote = note;
      this.audit('sos.resolve', `sos/${alertId}`, note);
      this.db.sosEvents.emit(alert);
      return alert;
    });
  }

  private startTicker(): void {
    this.watcherCount++;
    if (this.ticker) return;
    this.ticker = setInterval(() => {
      for (const alert of Object.values(this.db.sosAlerts)) {
        if (alert.status !== 'active') continue;
        const last = alert.trail[alert.trail.length - 1];
        // Small deterministic drift north-west so the trail visibly moves.
        alert.trail.push({
          at: this.now(),
          point: {
            latitude: last.point.latitude + 0.0007,
            longitude: last.point.longitude - 0.0009,
          },
        });
        const job = this.db.jobs[alert.jobId];
        if (job?.livePosition) job.livePosition = alert.trail[alert.trail.length - 1].point;
        this.db.sosEvents.emit(alert);
      }
    }, this.behavior.sosTickIntervalMs);
    // Never keep a Node process alive just for the mock ticker.
    if (typeof this.ticker === 'object' && 'unref' in this.ticker) this.ticker.unref();
  }

  private stopTicker(): void {
    this.watcherCount = Math.max(0, this.watcherCount - 1);
    if (this.watcherCount === 0 && this.ticker) {
      clearInterval(this.ticker);
      this.ticker = null;
    }
  }
}

export class MockRiskRepository extends MockRepo {
  async listCases(status?: RiskCase['status']): Promise<RiskCase[]> {
    await this.gate();
    this.requirePermission('risk.read');
    return Object.values(this.db.riskCases).filter((c) => !status || c.status === status);
  }

  async getCase(caseId: string): Promise<RiskCase> {
    await this.gate();
    this.requirePermission('risk.read');
    const riskCase = this.db.riskCases[caseId];
    if (!riskCase) throw new AppError(ErrorCodes.unknown);
    return riskCase;
  }

  async markReviewed(caseId: string, idempotencyKey: string): Promise<RiskCase> {
    await this.gate();
    const admin = this.requirePermission('risk.review');
    return this.idempotent(`risk.review:${caseId}`, idempotencyKey, '', () => {
      const riskCase = this.db.riskCases[caseId];
      if (!riskCase) throw new AppError(ErrorCodes.unknown);
      if (riskCase.status !== 'open') throw new AppError(ErrorCodes.alreadyReviewed);
      riskCase.status = 'reviewed';
      riskCase.reviewedByAdminId = admin.id;
      this.audit('risk.mark_reviewed', `risk/${caseId}`);
      return riskCase;
    });
  }

  async escalate(caseId: string, idempotencyKey: string): Promise<RiskCase> {
    await this.gate();
    const admin = this.requirePermission('risk.review');
    return this.idempotent(`risk.escalate:${caseId}`, idempotencyKey, '', () => {
      const riskCase = this.db.riskCases[caseId];
      if (!riskCase) throw new AppError(ErrorCodes.unknown);
      if (riskCase.status === 'escalated') throw new AppError(ErrorCodes.invalidState);
      riskCase.status = 'escalated';
      riskCase.reviewedByAdminId = admin.id;
      this.audit('risk.escalate', `risk/${caseId}`);
      return riskCase;
    });
  }
}
