// Trust and safety over the backend's queues: disputes (resolved by
// resolve_dispute with a refund the server quotes), support tickets, the SOS
// operations feed (the ops:sos broadcast topic) and the fraud-flag review queue.

import { AppError, ErrorCodes } from '@/mocks/errors';
import type { Unsubscribe } from '@/mocks/repositories';
import type {
  DisputeCase,
  DisputeCaseStatus,
  DisputeEvidenceRef,
  DisputeResolutionAction,
  DisputeResolutionQuote,
  RiskCase,
  RiskCaseKind,
  SosAlertAdmin,
  SosStatus,
  SupportTicketAdmin,
} from '@/mocks/types';

import { SupabaseAdminRepo, money } from './base';
import { SupabaseGateway, type Row } from './gateway';

// ---------------------------------------------------------------------------
// Disputes
// ---------------------------------------------------------------------------

const DISPUTE_STATUS: Record<string, DisputeCaseStatus> = {
  open: 'open',
  under_review: 'in_review',
  resolved: 'resolved',
  withdrawn: 'withdrawn',
};

const EVIDENCE_KIND: Record<string, DisputeEvidenceRef['kind']> = {
  photo: 'photo',
  message_range: 'chat_excerpt',
  location_range: 'location_log',
  receipt: 'payment_record',
  call_record: 'payment_record',
  pin_log: 'location_log',
  note: 'note',
};

/** What each console action asks the server to refund, in basis points of the job. */
function refundBps(action: DisputeResolutionAction, partialPercent?: number): number {
  switch (action) {
    case 'refund_full':
      return 10_000;
    case 'refund_partial': {
      const pct = partialPercent ?? 50;
      if (!Number.isInteger(pct) || pct <= 0 || pct >= 100) {
        throw new AppError(ErrorCodes.invalidState);
      }
      return pct * 100;
    }
    case 'release_to_provider':
    case 'reject':
      return 0;
  }
}

/** resolve_dispute's resolution keys: lowercase, digits and underscore. */
const RESOLUTION_KEY: Record<DisputeResolutionAction, string> = {
  refund_full: 'full_refund',
  refund_partial: 'partial_refund',
  release_to_provider: 'released_to_provider',
  reject: 'dispute_rejected',
};

export class SupabaseDisputeRepository extends SupabaseAdminRepo {
  async listDisputes(status?: DisputeCaseStatus): Promise<DisputeCase[]> {
    const rows = await this.gw.selectList(
      'disputes',
      'id, request_id, opened_by, reason_code, status, assigned_officer_id, resolution_key, resolution_note, refund_minor, resolved_at, created_at',
      { orderBy: 'created_at', ascending: false, limit: 200 },
    );
    const cases = await this.cases(rows, false);
    return cases.filter((c) => !status || c.status === status);
  }

  async getDispute(disputeId: string): Promise<DisputeCase> {
    const row = await this.gw.selectSingle(
      'disputes',
      'id, request_id, opened_by, reason_code, status, assigned_officer_id, resolution_key, resolution_note, refund_minor, resolved_at, created_at',
      'id',
      disputeId,
    );
    if (!row) throw new AppError(ErrorCodes.notFound);
    return (await this.cases([row], true))[0]!;
  }

  /** Takes the case: under_review and assigned to the caller. */
  async assignDispute(disputeId: string, idempotencyKey: string): Promise<DisputeCase> {
    await this.gw.rpc('assign_dispute', {
      p_idempotency_key: idempotencyKey,
      p_dispute_id: disputeId,
      p_officer_id: await this.selfId(),
    });
    return this.getDispute(disputeId);
  }

  async getResolutionQuote(
    disputeId: string,
    action: DisputeResolutionAction,
    partialPercent?: number,
  ): Promise<DisputeResolutionQuote> {
    const row = SupabaseAdminRepo.first(
      await this.gw.rpcRows('dispute_resolution_quote', {
        p_dispute_id: disputeId,
        p_refund_bps: refundBps(action, partialPercent),
      }),
    );
    const currency = row['currency'];
    return {
      action,
      refundToCustomer: money(row['refund_minor'], currency),
      releaseToProvider: money(row['provider_minor'], currency),
      platformRetained: money(row['commission_minor'], currency),
    };
  }

  /**
   * Resolves with exactly the refund the server quoted. A written reason is required:
   * resolve_dispute refuses one without, because the parties are owed an explanation.
   */
  async resolveDispute(
    disputeId: string,
    action: DisputeResolutionAction,
    options: { partialPercent?: number; note?: string },
    idempotencyKey: string,
  ): Promise<DisputeCase> {
    await this.requireRecentMfa('disputes.resolve');
    const note = options.note?.trim() ?? '';
    if (note === '') throw new AppError('ERR_INVALID_ARGUMENT');
    const quote = await this.getResolutionQuote(disputeId, action, options.partialPercent);
    await this.gw.rpc('resolve_dispute', {
      p_idempotency_key: idempotencyKey,
      p_dispute_id: disputeId,
      p_resolution_key: RESOLUTION_KEY[action],
      p_refund_minor: quote.refundToCustomer.amountMinor,
      p_note: note,
    });
    return this.getDispute(disputeId);
  }

  private async cases(rows: Row[], detail: boolean): Promise<DisputeCase[]> {
    const requestIds = rows.map((r) => r['request_id']);
    const [requests, jobs, payments] = await Promise.all([
      this.gw.selectList('requests', 'id, customer_id, country_code', {
        inColumn: 'id',
        inValues: requestIds,
      }),
      this.gw.selectList('jobs', 'request_id, provider_id, agreed_amount_minor, currency', {
        inColumn: 'request_id',
        inValues: requestIds,
      }),
      this.gw.selectList('payments', 'request_id, kind, job_amount_minor, currency, status', {
        inColumn: 'request_id',
        inValues: requestIds,
      }),
    ]);
    const requestOf = new Map(requests.map((r) => [String(r['id']), r]));
    const jobOf = new Map(jobs.map((j) => [String(j['request_id']), j]));
    // The opener is the customer whether or not the request itself is in the caller's scope.
    const names = await this.names([
      ...rows.map((r) => r['opened_by']),
      ...requests.map((r) => r['customer_id']),
      ...jobs.map((j) => j['provider_id']),
    ]);
    const evidence = detail
      ? await this.gw.selectList(
          'dispute_evidence',
          'id, dispute_id, kind, note, submitted_by, created_at',
          { inColumn: 'dispute_id', inValues: rows.map((r) => r['id']), orderBy: 'created_at' },
        )
      : [];

    return rows.map((row): DisputeCase => {
      const requestId = String(row['request_id']);
      const request = requestOf.get(requestId);
      const job = jobOf.get(requestId);
      const payment = payments.find(
        (p) => String(p['request_id']) === requestId && p['kind'] === 'job',
      );
      const customerId = String(request?.['customer_id'] ?? row['opened_by']);
      const providerId = String(job?.['provider_id'] ?? '');
      const currency = payment?.['currency'] ?? job?.['currency'] ?? '';
      const resolutionKey = row['resolution_key'] ? String(row['resolution_key']) : undefined;
      const action = (Object.entries(RESOLUTION_KEY).find(([, key]) => key === resolutionKey)?.[0] ??
        undefined) as DisputeResolutionAction | undefined;
      return {
        id: String(row['id']),
        jobId: requestId,
        country: String(request?.['country_code'] ?? ''),
        customerId,
        customerName: SupabaseAdminRepo.nameOf(names, customerId),
        providerId,
        providerName: SupabaseAdminRepo.nameOf(names, providerId),
        reasonKey: String(row['reason_code']),
        status: action === 'reject' ? 'rejected' : (DISPUTE_STATUS[String(row['status'])] ?? 'open'),
        openedAt: SupabaseGateway.asTimestamp(row['created_at']),
        assignedToAdminId: row['assigned_officer_id'] ? String(row['assigned_officer_id']) : undefined,
        evidence: evidence
          .filter((e) => String(e['dispute_id']) === String(row['id']))
          .map((e) => ({
            id: String(e['id']),
            kind: EVIDENCE_KIND[String(e['kind'])] ?? 'note',
            label: String(e['note'] ?? e['kind']),
            uploadedBy:
              String(e['submitted_by']) === customerId
                ? 'customer'
                : String(e['submitted_by']) === providerId
                  ? 'provider'
                  : 'system',
            uploadedAt: SupabaseGateway.asTimestamp(e['created_at']),
          })),
        heldAmount: money(payment?.['job_amount_minor'] ?? job?.['agreed_amount_minor'] ?? 0, currency),
        resolution:
          action && row['resolved_at']
            ? {
                action,
                quote: {
                  action,
                  refundToCustomer: money(row['refund_minor'] ?? 0, currency),
                  // What was released is the ledger's to say; the case records the refund.
                  releaseToProvider: money(0, currency),
                  platformRetained: money(0, currency),
                },
                byAdminId: String(row['assigned_officer_id'] ?? ''),
                at: SupabaseGateway.asTimestamp(row['resolved_at']),
              }
            : undefined,
      };
    });
  }
}

// ---------------------------------------------------------------------------
// Support
// ---------------------------------------------------------------------------

export class SupabaseSupportRepository extends SupabaseAdminRepo {
  async listTickets(status?: SupportTicketAdmin['status']): Promise<SupportTicketAdmin[]> {
    const rows = await this.gw.selectList(
      'support_tickets',
      'id, user_id, request_id, category, status, priority, assignee_id, created_at',
      { orderBy: 'created_at', ascending: false, limit: 200 },
    );
    const tickets = await this.tickets(rows, []);
    return tickets.filter((t) => !status || t.status === status);
  }

  async getTicket(ticketId: string): Promise<SupportTicketAdmin> {
    const row = await this.gw.selectSingle(
      'support_tickets',
      'id, user_id, request_id, category, status, priority, assignee_id, created_at',
      'id',
      ticketId,
    );
    if (!row) throw new AppError(ErrorCodes.notFound);
    const messages = await this.gw.selectList(
      'ticket_messages',
      'id, ticket_id, author_id, body, internal, created_at',
      { column: 'ticket_id', value: ticketId, orderBy: 'created_at' },
    );
    return (await this.tickets([row], messages))[0]!;
  }

  async assignTicket(ticketId: string, idempotencyKey: string): Promise<SupportTicketAdmin> {
    await this.gw.rpc('update_ticket', {
      p_idempotency_key: idempotencyKey,
      p_ticket_id: ticketId,
      p_assignee_id: await this.selfId(),
    });
    return this.getTicket(ticketId);
  }

  async replyTicket(
    ticketId: string,
    body: string,
    idempotencyKey: string,
  ): Promise<SupportTicketAdmin> {
    await this.gw.rpc('reply_to_ticket', {
      p_idempotency_key: idempotencyKey,
      p_ticket_id: ticketId,
      p_body: body,
      p_internal: false,
    });
    return this.getTicket(ticketId);
  }

  async closeTicket(ticketId: string, idempotencyKey: string): Promise<SupportTicketAdmin> {
    await this.gw.rpc('update_ticket', {
      p_idempotency_key: idempotencyKey,
      p_ticket_id: ticketId,
      p_status: 'closed',
    });
    return this.getTicket(ticketId);
  }

  private async tickets(rows: Row[], messages: Row[]): Promise<SupportTicketAdmin[]> {
    const names = await this.names(rows.map((r) => r['user_id']));
    const profiles = await this.gw.selectList('profiles', 'user_id, country_code', {
      inColumn: 'user_id',
      inValues: rows.map((r) => r['user_id']),
    });
    const countryOf = new Map(profiles.map((p) => [String(p['user_id']), p['country_code']]));
    return rows.map((row) => {
      const userId = String(row['user_id']);
      const raw = String(row['status']);
      const priority = Number(row['priority'] ?? 3);
      return {
        id: String(row['id']),
        userId,
        userName: SupabaseAdminRepo.nameOf(names, userId),
        country: String(countryOf.get(userId) ?? ''),
        subject: String(row['category'] ?? '').replace(/_/g, ' '),
        status:
          raw === 'resolved' || raw === 'closed'
            ? 'closed'
            : row['assignee_id']
              ? 'assigned'
              : 'open',
        priority: priority <= 2 ? 'high' : priority === 3 ? 'normal' : 'low',
        assignedToAdminId: row['assignee_id'] ? String(row['assignee_id']) : undefined,
        createdAt: SupabaseGateway.asTimestamp(row['created_at']),
        messages: messages
          .filter((m) => String(m['ticket_id']) === String(row['id']))
          .map((m) => ({
            id: String(m['id']),
            author: String(m['author_id']) === userId ? ('customer' as const) : ('agent' as const),
            body: String(m['body'] ?? ''),
            at: SupabaseGateway.asTimestamp(m['created_at']),
          })),
      };
    });
  }
}

// ---------------------------------------------------------------------------
// SOS
// ---------------------------------------------------------------------------

const SOS_STATUS: Record<string, SosStatus> = {
  open: 'active',
  acknowledged: 'acknowledged',
  dispatched: 'acknowledged',
  resolved: 'resolved',
  false_alarm: 'resolved',
};

const SOS_COLUMNS =
  'id, request_id, raised_by, point, status, ops_assignee_id, ops_ack_at, resolution_note, resolved_at, created_at';

export class SupabaseSosRepository extends SupabaseAdminRepo {
  async listAlerts(status?: SosAlertAdmin['status']): Promise<SosAlertAdmin[]> {
    const rows = await this.gw.selectList('sos_incidents', SOS_COLUMNS, {
      orderBy: 'created_at',
      ascending: false,
      limit: 100,
    });
    const alerts = await this.alerts(rows);
    return alerts.filter((a) => !status || a.status === status);
  }

  async getAlert(alertId: string): Promise<SosAlertAdmin> {
    const row = await this.gw.selectSingle('sos_incidents', SOS_COLUMNS, 'id', alertId);
    if (!row) throw new AppError(ErrorCodes.notFound);
    return (await this.alerts([row]))[0]!;
  }

  /** Re-reads an incident whenever the ops:sos topic says it changed (ADR-0009). */
  watchAlerts(listener: (alert: SosAlertAdmin) => void): Unsubscribe {
    return this.gw.watchBroadcast('ops:sos', (payload) => {
      const id = payload['incident_id'];
      if (typeof id !== 'string') return;
      this.getAlert(id)
        .then(listener)
        .catch(() => {});
    });
  }

  async acknowledge(alertId: string, idempotencyKey: string): Promise<SosAlertAdmin> {
    await this.gw.rpc('update_sos_incident', {
      p_idempotency_key: idempotencyKey,
      p_incident_id: alertId,
      p_status: 'acknowledged',
    });
    return this.getAlert(alertId);
  }

  async resolve(alertId: string, note: string, idempotencyKey: string): Promise<SosAlertAdmin> {
    await this.gw.rpc('update_sos_incident', {
      p_idempotency_key: idempotencyKey,
      p_incident_id: alertId,
      p_status: 'resolved',
      p_note: note,
    });
    return this.getAlert(alertId);
  }

  private async alerts(rows: Row[]): Promise<SosAlertAdmin[]> {
    const names = await this.names(rows.map((r) => r['raised_by']));
    const requests = await this.gw.selectList('requests', 'id, customer_id, country_code', {
      inColumn: 'id',
      inValues: rows.map((r) => r['request_id']).filter((id) => id !== null),
    });
    const profiles = await this.gw.selectList('profiles', 'user_id, country_code', {
      inColumn: 'user_id',
      inValues: rows.map((r) => r['raised_by']),
    });
    const requestOf = new Map(requests.map((r) => [String(r['id']), r]));
    const countryOf = new Map(profiles.map((p) => [String(p['user_id']), p['country_code']]));
    return rows.map((row) => {
      const raisedBy = String(row['raised_by']);
      const request = requestOf.get(String(row['request_id']));
      const coords = (row['point'] as Row | null)?.['coordinates'];
      const at = SupabaseGateway.asTimestamp(row['created_at']);
      return {
        id: String(row['id']),
        jobId: row['request_id'] ? String(row['request_id']) : '',
        country: String(request?.['country_code'] ?? countryOf.get(raisedBy) ?? ''),
        triggeredBy:
          request && String(request['customer_id']) !== raisedBy ? 'provider' : 'customer',
        userName: SupabaseAdminRepo.nameOf(names, raisedBy),
        status: SOS_STATUS[String(row['status'])] ?? 'active',
        triggeredAt: at,
        acknowledgedByAdminId: row['ops_assignee_id'] ? String(row['ops_assignee_id']) : undefined,
        acknowledgedAt: SupabaseGateway.asOptionalTimestamp(row['ops_ack_at']),
        resolvedAt: SupabaseGateway.asOptionalTimestamp(row['resolved_at']),
        resolutionNote: row['resolution_note'] ? String(row['resolution_note']) : undefined,
        trail: Array.isArray(coords)
          ? [{ at, point: { longitude: Number(coords[0]), latitude: Number(coords[1]) } }]
          : [],
      };
    });
  }
}

// ---------------------------------------------------------------------------
// Risk
// ---------------------------------------------------------------------------

export class SupabaseRiskRepository extends SupabaseAdminRepo {
  async listCases(status?: RiskCase['status']): Promise<RiskCase[]> {
    const rows = await this.gw.selectList(
      'fraud_flags',
      'id, subject_kind, subject_id, rule_key, score, status, details, reviewer_id, created_at',
      { orderBy: 'created_at', ascending: false, limit: 200 },
    );
    const cases = await this.cases(rows);
    return cases.filter((c) => !status || c.status === status);
  }

  async getCase(caseId: string): Promise<RiskCase> {
    const row = await this.gw.selectSingle(
      'fraud_flags',
      'id, subject_kind, subject_id, rule_key, score, status, details, reviewer_id, created_at',
      'id',
      caseId,
    );
    if (!row) throw new AppError(ErrorCodes.notFound);
    return (await this.cases([row]))[0]!;
  }

  /** Cleared: reviewed and not fraud. A confirmed flag bans nobody (OD-25). */
  async markReviewed(caseId: string, idempotencyKey: string): Promise<RiskCase> {
    await this.gw.rpc('review_fraud_flag', {
      p_idempotency_key: idempotencyKey,
      p_flag_id: caseId,
      p_confirmed: false,
      p_note: 'Reviewed in the admin console: not fraud.',
    });
    return this.getCase(caseId);
  }

  async escalate(caseId: string, idempotencyKey: string): Promise<RiskCase> {
    await this.gw.rpc('review_fraud_flag', {
      p_idempotency_key: idempotencyKey,
      p_flag_id: caseId,
      p_confirmed: true,
      p_note: 'Confirmed in the admin console for follow-up.',
    });
    return this.getCase(caseId);
  }

  private async cases(rows: Row[]): Promise<RiskCase[]> {
    const users = rows.filter((r) => r['subject_kind'] === 'user').map((r) => r['subject_id']);
    const names = await this.names(users);
    const profiles = await this.gw.selectList('profiles', 'user_id, country_code', {
      inColumn: 'user_id',
      inValues: users,
    });
    const countryOf = new Map(profiles.map((p) => [String(p['user_id']), p['country_code']]));
    return rows.map((row) => {
      const subject = String(row['subject_id']);
      const details = (row['details'] ?? {}) as Row;
      const status = String(row['status']);
      return {
        id: String(row['id']),
        kind: String(row['rule_key']) as RiskCaseKind,
        country: String(countryOf.get(subject) ?? ''),
        subjectUserId: subject,
        subjectName:
          row['subject_kind'] === 'user'
            ? SupabaseAdminRepo.nameOf(names, subject)
            : `${String(row['subject_kind'])} ${subject.slice(0, 8)}…`,
        signals: [
          `score ${String(row['score'])}`,
          ...Object.entries(details).map(([k, v]) => `${k}: ${typeof v === 'object' ? JSON.stringify(v) : String(v)}`),
        ],
        status: status === 'open' ? 'open' : status === 'confirmed' ? 'escalated' : 'reviewed',
        openedAt: SupabaseGateway.asTimestamp(row['created_at']),
        reviewedByAdminId: row['reviewer_id'] ? String(row['reviewer_id']) : undefined,
      };
    });
  }
}
