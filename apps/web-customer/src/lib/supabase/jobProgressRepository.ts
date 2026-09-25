// JobProgressRepository over Supabase (customer scope): completion
// confirmation goes through `confirm_completion` (the server owns the state
// machine), and handover PINs come from `reveal_job_pin` on demand — never
// stored on the entity. The provider-side verbs (set_job_status, verify_pin,
// submit_proof) stay out of the customer app, as on the mock. Mirrors
// packages/suskii_data/lib/src/supabase/supabase_job_progress_repository.dart.

import { AppError, ErrorCodes } from '@/mocks/errors';
import type { HandoverPinKind, JobRequest } from '@/mocks/types';

import type { SupabaseGateway } from './gateway';
import { loadJobRequestRow } from './requestRepository';

export class SupabaseJobProgressRepository {
  constructor(private readonly gateway: SupabaseGateway) {}

  /** Customer confirms completion (customer-only, from
   * COMPLETED_BY_PROVIDER — the server enforces both). The RPC returns the
   * new status scalar; the entity needs the full row, so re-select. */
  async confirmCompletion(jobId: string, idempotencyKey: string): Promise<JobRequest> {
    await this.gateway.rpc('confirm_completion', {
      p_idempotency_key: idempotencyKey,
      p_request_id: jobId,
    });
    const updated = await loadJobRequestRow(this.gateway, jobId);
    if (updated === null) throw new AppError(ErrorCodes.unknown);
    return updated;
  }

  /** Reveal-on-demand handover PIN. The server rotates on every reveal —
   * show it once, never cache it. */
  async revealHandoverPin(jobId: string, kind: HandoverPinKind): Promise<string> {
    const pin = await this.gateway.rpc('reveal_job_pin', {
      p_request_id: jobId,
      p_kind: kind,
    });
    return pin as string;
  }
}
