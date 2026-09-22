// Verification queues: claim / approve / reject, plus short-lived document
// viewing grants (60s tokens, role-gated, reauth-gated, audit-logged).

import { DOCUMENT_VIEW_TTL_MS } from '../behavior';
import { AppError, ErrorCodes } from '../errors';
import type {
  DocumentViewGrant,
  VerificationKind,
  VerificationQueueItem,
  VerificationQueueStatus,
} from '../types';
import { MockRepo } from './base';

export interface VerificationFilter {
  kind?: VerificationKind;
  status?: VerificationQueueStatus;
  country?: string;
}

export class MockVerificationRepository extends MockRepo {
  async listQueue(filter?: VerificationFilter): Promise<VerificationQueueItem[]> {
    await this.gate();
    this.requirePermission('verification.read');
    return Object.values(this.db.verificationQueue).filter((item) => {
      if (filter?.kind && item.kind !== filter.kind) return false;
      if (filter?.status && item.status !== filter.status) return false;
      if (filter?.country && item.country !== filter.country) return false;
      return true;
    });
  }

  async getItem(itemId: string): Promise<VerificationQueueItem> {
    await this.gate();
    this.requirePermission('verification.read');
    const item = this.db.verificationQueue[itemId];
    if (!item) throw new AppError(ErrorCodes.unknown);
    return item;
  }

  async claim(itemId: string, idempotencyKey: string): Promise<VerificationQueueItem> {
    await this.gate();
    const admin = this.requirePermission('verification.claim');
    return this.idempotent(`verification.claim:${itemId}`, idempotencyKey, '', () => {
      const item = this.db.verificationQueue[itemId];
      if (!item) throw new AppError(ErrorCodes.unknown);
      if (item.status === 'approved' || item.status === 'rejected') {
        throw new AppError(ErrorCodes.alreadyReviewed);
      }
      if (item.status === 'in_review') throw new AppError(ErrorCodes.invalidState);
      item.status = 'in_review';
      item.claimedByAdminId = admin.id;
      this.audit('verification.claim', `verification/${itemId}`);
      return item;
    });
  }

  async approve(itemId: string, idempotencyKey: string): Promise<VerificationQueueItem> {
    await this.gate();
    this.requirePermission('verification.review');
    return this.idempotent(`verification.approve:${itemId}`, idempotencyKey, '', () => {
      const item = this.requireReviewable(itemId);
      item.status = 'approved';
      item.reviewedAt = this.now();
      this.setSubjectVerification(item, 'verified');
      this.audit('verification.approve', `verification/${itemId}`);
      return item;
    });
  }

  async reject(
    itemId: string,
    reasonKey: string,
    idempotencyKey: string,
  ): Promise<VerificationQueueItem> {
    await this.gate();
    this.requirePermission('verification.review');
    return this.idempotent(
      `verification.reject:${itemId}`,
      idempotencyKey,
      reasonKey,
      () => {
        const item = this.requireReviewable(itemId);
        item.status = 'rejected';
        item.reviewedAt = this.now();
        item.decisionReasonKey = reasonKey;
        this.setSubjectVerification(item, 'rejected');
        this.audit('verification.reject', `verification/${itemId}`, reasonKey);
        return item;
      },
    );
  }

  /**
   * Issues a short-lived (60s) document viewing grant. Sensitive: requires
   * reauth within 5 minutes; every grant is audit-logged. The URL is opaque
   * — the console must re-request a grant once it expires.
   */
  async requestDocumentView(
    itemId: string,
    idempotencyKey: string,
  ): Promise<DocumentViewGrant> {
    await this.gate();
    this.requireSensitive('verification.view_document');
    return this.idempotent(
      `verification.view_document:${itemId}`,
      idempotencyKey,
      '',
      () => {
        const item = this.db.verificationQueue[itemId];
        if (!item) throw new AppError(ErrorCodes.unknown);
        const grant: DocumentViewGrant = {
          itemId,
          viewToken: globalThis.crypto.randomUUID(),
          url: `https://docs.suskii.invalid/v/${globalThis.crypto.randomUUID()}`,
          expiresAt: new Date(this.now().getTime() + DOCUMENT_VIEW_TTL_MS),
        };
        this.db.documentViewGrants[grant.viewToken] = grant;
        this.audit('verification.view_document', `verification/${itemId}`);
        return grant;
      },
    );
  }

  /** Server-side check the document service would perform on the token. */
  async validateDocumentView(viewToken: string): Promise<DocumentViewGrant> {
    await this.gate();
    this.requirePermission('verification.view_document');
    const grant = this.db.documentViewGrants[viewToken];
    if (!grant) throw new AppError(ErrorCodes.unknown);
    if (grant.expiresAt.getTime() <= this.now().getTime()) {
      delete this.db.documentViewGrants[viewToken];
      throw new AppError(ErrorCodes.sessionExpired);
    }
    return grant;
  }

  private requireReviewable(itemId: string): VerificationQueueItem {
    const item = this.db.verificationQueue[itemId];
    if (!item) throw new AppError(ErrorCodes.unknown);
    if (item.status === 'approved' || item.status === 'rejected') {
      throw new AppError(ErrorCodes.alreadyReviewed);
    }
    if (item.status !== 'in_review') throw new AppError(ErrorCodes.invalidState);
    return item;
  }

  private setSubjectVerification(
    item: VerificationQueueItem,
    status: 'verified' | 'rejected',
  ): void {
    switch (item.subjectType) {
      case 'user': {
        const s = this.db.users[item.subjectId];
        if (s) s.verificationStatus = status;
        break;
      }
      case 'provider': {
        const s = this.db.providers[item.subjectId];
        if (s) s.verificationStatus = status;
        break;
      }
      case 'business': {
        const s = this.db.businesses[item.subjectId];
        if (s) s.verificationStatus = status;
        break;
      }
      case 'worker': {
        const s = this.db.workers[item.subjectId];
        if (s) s.verificationStatus = status;
        break;
      }
      case 'vehicle': {
        const s = this.db.vehicles[item.subjectId];
        if (s) s.verificationStatus = status;
        break;
      }
    }
  }
}
