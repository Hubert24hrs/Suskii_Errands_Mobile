// The verification queues: KYC steps waiting for an officer (kyc_review_queue) and
// businesses waiting for a decision (business_verification_queue). There is no
// claim on the backend — a step in the queue is already in review, and the
// no-self-review rule is the server's — so claim() is a no-op that returns the item.

import { AppError, ErrorCodes } from '@/mocks/errors';
import type { VerificationFilter } from '@/mocks/repositories';
import type {
  DocumentViewGrant,
  VerificationKind,
  VerificationQueueItem,
} from '@/mocks/types';

import { SupabaseAdminRepo } from './base';
import { SupabaseGateway, type Row } from './gateway';

const KIND_OF_STEP: Record<string, VerificationKind> = {
  government_id: 'id_document',
  id_document_capture: 'id_document',
  customer_facial: 'facial',
  provider_facial: 'facial',
  police_clearance: 'police_clearance',
  vehicle_documents: 'vehicle_document',
  address: 'provider_details',
  guarantor: 'provider_details',
  credentials: 'provider_details',
  payout_account: 'provider_details',
};

const PROVIDER_STEPS = new Set([
  'provider_facial',
  'id_document_capture',
  'police_clearance',
  'address',
  'guarantor',
  'credentials',
  'payout_account',
  'vehicle_documents',
]);

/**
 * The console's rejection reasons, as the keys the apps localise. A rejection the user
 * cannot read is a rejection they cannot act on (audit 2026-10-13, Z.10).
 */
export const KYC_REJECTION_KEYS: Record<string, string> = {
  docUnreadable: 'kycRejectDocUnreadable',
  docExpired: 'kycRejectDocExpired',
  mismatch: 'kycRejectMismatch',
  failedLiveness: 'kycRejectFailedLiveness',
  other: 'kycRejectOther',
};

const BUSINESS_REJECTION_KEYS: Record<string, string> = {
  docUnreadable: 'business_doc_unreadable',
  docExpired: 'business_doc_expired',
  mismatch: 'business_details_mismatch',
  failedLiveness: 'business_details_mismatch',
  other: 'business_rejected_other',
};

export class SupabaseVerificationRepository extends SupabaseAdminRepo {
  /** Items decided in this session, so a drawer left open still shows the outcome. */
  private readonly decided = new Map<string, VerificationQueueItem>();
  private readonly grants = new Map<string, DocumentViewGrant>();

  async listQueue(filter?: VerificationFilter): Promise<VerificationQueueItem[]> {
    const [steps, businesses] = await Promise.all([
      this.gw.rpcRows('kyc_review_queue', { p_limit: 200 }),
      this.gw.rpcRows('business_verification_queue', { p_limit: 200 }),
    ]);
    const names = await this.names(steps.map((s) => s['user_id']));
    const items = [
      ...steps.map((row) => this.stepItem(row, names)),
      ...businesses.map((row) => this.businessItem(row)),
      ...[...this.decided.values()],
    ];
    const seen = new Set<string>();
    return items.filter((item) => {
      if (seen.has(item.id)) return false;
      seen.add(item.id);
      if (filter?.kind && item.kind !== filter.kind) return false;
      if (filter?.status && item.status !== filter.status) return false;
      if (filter?.country && item.country !== filter.country) return false;
      return true;
    });
  }

  async getItem(itemId: string): Promise<VerificationQueueItem> {
    const decided = this.decided.get(itemId);
    if (decided) return decided;
    const item = (await this.listQueue()).find((i) => i.id === itemId);
    if (!item) throw new AppError(ErrorCodes.notFound);
    return item;
  }

  async claim(itemId: string, _idempotencyKey: string): Promise<VerificationQueueItem> {
    return this.getItem(itemId);
  }

  async approve(itemId: string, idempotencyKey: string): Promise<VerificationQueueItem> {
    const item = await this.getItem(itemId);
    if (item.subjectType === 'business') {
      await this.gw.rpc('decide_business_verification', {
        p_idempotency_key: idempotencyKey,
        p_organization_id: item.subjectId,
        p_approve: true,
      });
    } else {
      await this.gw.rpc('decide_kyc_step', {
        p_idempotency_key: idempotencyKey,
        p_step_id: item.id,
        p_decision: 'approved',
      });
    }
    return this.markDecided(item, 'approved');
  }

  async reject(
    itemId: string,
    reasonKey: string,
    idempotencyKey: string,
  ): Promise<VerificationQueueItem> {
    const item = await this.getItem(itemId);
    if (item.subjectType === 'business') {
      await this.gw.rpc('decide_business_verification', {
        p_idempotency_key: idempotencyKey,
        p_organization_id: item.subjectId,
        p_approve: false,
        p_reason_key: BUSINESS_REJECTION_KEYS[reasonKey] ?? 'business_rejected_other',
      });
    } else {
      await this.gw.rpc('decide_kyc_step', {
        p_idempotency_key: idempotencyKey,
        p_step_id: item.id,
        p_decision: 'rejected',
        p_reason_key: KYC_REJECTION_KEYS[reasonKey] ?? 'kycRejectOther',
      });
    }
    return this.markDecided(item, 'rejected', reasonKey);
  }

  /**
   * A 60-second link to one document. The Edge Function runs request_document_access as
   * the officer first, so the database audits the read before any URL exists.
   */
  async requestDocumentView(
    itemId: string,
    _idempotencyKey: string,
    uploadRef?: string,
  ): Promise<DocumentViewGrant> {
    await this.requireRecentMfa('verification.view_document');
    const item = await this.getItem(itemId);
    const ref = uploadRef ?? item.uploadRefs?.[0];
    if (!ref) throw new AppError(ErrorCodes.notFound);
    const response = await this.gw.invoke('kyc-document-url', {
      upload_ref: ref,
      reason_code: 'kyc_review',
    });
    const grant: DocumentViewGrant = {
      itemId,
      viewToken: ref,
      url: String(response['url']),
      expiresAt: SupabaseGateway.asTimestamp(response['expires_at']),
    };
    this.grants.set(grant.viewToken, grant);
    return grant;
  }

  async validateDocumentView(viewToken: string): Promise<DocumentViewGrant> {
    const grant = this.grants.get(viewToken);
    if (!grant) throw new AppError(ErrorCodes.notFound);
    if (grant.expiresAt.getTime() <= Date.now()) {
      this.grants.delete(viewToken);
      throw new AppError(ErrorCodes.sessionExpired);
    }
    return grant;
  }

  private stepItem(row: Row, names: Map<string, string>): VerificationQueueItem {
    const stepKind = String(row['kind']);
    return {
      id: String(row['step_id']),
      kind: KIND_OF_STEP[stepKind] ?? 'provider_details',
      stepKind,
      subjectType: PROVIDER_STEPS.has(stepKind) ? 'provider' : 'user',
      subjectId: String(row['user_id']),
      subjectName: SupabaseAdminRepo.nameOf(names, row['user_id']),
      country: String(row['country_code'] ?? ''),
      submittedAt: SupabaseGateway.asTimestamp(row['submitted_at']),
      status: 'in_review',
      // A resubmission has already waited once.
      priority: Number(row['attempt_count'] ?? 1) > 1 ? 'high' : 'normal',
      uploadRefs: Array.isArray(row['upload_refs']) ? (row['upload_refs'] as string[]) : [],
    };
  }

  private businessItem(row: Row): VerificationQueueItem {
    const id = String(row['organization_id']);
    return {
      id: `org:${id}`,
      kind: 'business_document',
      subjectType: 'business',
      subjectId: id,
      subjectName: String(row['legal_name'] ?? ''),
      country: String(row['country_code'] ?? ''),
      submittedAt: SupabaseGateway.asTimestamp(row['created_at']),
      status: 'in_review',
      priority: 'normal',
      uploadRefs: [],
    };
  }

  private markDecided(
    item: VerificationQueueItem,
    status: 'approved' | 'rejected',
    reasonKey?: string,
  ): VerificationQueueItem {
    const decided: VerificationQueueItem = {
      ...item,
      status,
      reviewedAt: new Date(),
      decisionReasonKey: reasonKey,
    };
    this.decided.set(item.id, decided);
    return decided;
  }
}
