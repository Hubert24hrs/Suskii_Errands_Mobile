// RequestRepository over Supabase: drafts/publish/cancel go through the
// contract RPCs (the server owns the state machine and fees); reads are
// RLS-scoped selects on `requests` with the category-key and to-one `jobs`
// embeds. Mirrors
// packages/suskii_data/lib/src/supabase/supabase_request_repository.dart.

import { AppError, ErrorCodes } from '@/mocks/errors';
import {
  isTerminalJobStatus,
  type CreateRequestInput,
  type JobRequest,
  type JobStatus,
  type UpdateRequestInput,
} from '@/mocks/types';
import type { Unsubscribe } from '@/mocks/repos/base';

import { SupabaseGateway } from './gateway';
import { jobRequestFromRow } from './mappers';

/** Explicit columns (contracts v1 narrows column grants on several tables).
 * `service_categories(key)` embeds the category key via the category_id FK
 * (rows store the uuid; the entity carries the key). `jobs(...)` embeds the
 * to-one job row that exists once an offer has been accepted. */
export const requestRowColumns =
  'id, customer_id, is_custom_category, custom_category_label, ' +
  'description, urgency, status, pickup_point, pickup_label, ' +
  'pickup_landmark_note, destination_point, destination_label, ' +
  'destination_landmark_note, scheduled_at, preferred_price_minor, ' +
  'item_float_minor, declared_value_minor, currency, expires_at, ' +
  'created_at, service_categories(key), ' +
  'jobs(provider_id, agreed_amount_minor, currency, commission_rate_bps, ' +
  'commission_minor, net_minor, estimated_gateway_fee_minor, ' +
  'actual_gateway_fee_minor, tip_minor)';

/** Loads one request row (with embeds) and its media paths, mapped to the
 * entity. Shared with the job-progress repository, whose status mutations
 * return the same entity. */
export async function loadJobRequestRow(
  gateway: SupabaseGateway,
  jobId: string,
): Promise<JobRequest | null> {
  const row = await gateway.selectSingle('requests', requestRowColumns, 'id', jobId);
  if (row === null) return null;
  const media = await gateway.selectList('request_media', 'storage_path', {
    column: 'request_id',
    value: jobId,
    orderBy: 'created_at',
  });
  return jobRequestFromRow(
    row,
    media.map((m) => m['storage_path'] as string),
  );
}

const JOB_STATUSES: readonly JobStatus[] = [
  'draft',
  'published',
  'offers_received',
  'negotiating',
  'agreed',
  'payment_pending',
  'paid_held',
  'assigned',
  'en_route',
  'arrived',
  'in_progress',
  'completed_by_provider',
  'confirmed',
  'settlement_pending',
  'settled',
  'closed',
  'cancelled',
  'expired',
  'disputed',
  'refunded',
];

// NOTE: ordered newest-first (ascending: false), matching the mock and the
// screens' newest-first list contract — and making the created_at cursor
// below paginate correctly (lt + descending is a proper keyset). The Dart
// M9.2 repo relies on its gateway's ascending default; flagged in HANDOFF as
// a suspected mobile-side inconsistency to review.
const ACTIVE_STATUSES = JOB_STATUSES.filter((s) => !isTerminalJobStatus(s));
const TERMINAL_STATUSES = JOB_STATUSES.filter((s) => isTerminalJobStatus(s));

export class SupabaseRequestRepository {
  constructor(private readonly gateway: SupabaseGateway) {}

  async getMyActiveJobs(): Promise<JobRequest[]> {
    const rows = await this.gateway.selectList('requests', requestRowColumns, {
      inColumn: 'status',
      inValues: ACTIVE_STATUSES,
      orderBy: 'created_at',
      ascending: false,
    });
    return rows.map((row) => jobRequestFromRow(row));
  }

  async getMyRequestHistory(options?: {
    cursor?: string;
    limit?: number;
  }): Promise<JobRequest[]> {
    // Cursor is the last row's created_at (ISO-8601) — an opaque page token.
    // (The mock uses the last row's id instead; no screen passes a cursor
    // today.)
    const rows = await this.gateway.selectList('requests', requestRowColumns, {
      inColumn: 'status',
      inValues: TERMINAL_STATUSES,
      ltColumn: options?.cursor != null ? 'created_at' : undefined,
      ltValue: options?.cursor,
      orderBy: 'created_at',
      ascending: false,
      limit: options?.limit ?? 20,
    });
    return rows.map((row) => jobRequestFromRow(row));
  }

  /** Emits the current job (if readable) immediately, then on every change.
   * The requests row carries the status; every jobs-row money change happens
   * in the same transaction as a requests status change, so re-reading the
   * joins on each requests event stays consistent. Media are immutable after
   * creation, but cheap to re-read here (one job only). */
  watchJob(jobId: string, onChange: (job: JobRequest) => void): Unsubscribe {
    let active = true;
    const load = async (): Promise<void> => {
      try {
        const job = await loadJobRequestRow(this.gateway, jobId);
        if (active && job !== null) onChange(job);
      } catch {
        // Keep the subscription; the next event retries the fetch.
      }
    };
    void load();
    const unsubscribe = this.gateway.watchRows(
      'requests',
      'id',
      () => void load(),
      { column: 'id', value: jobId, filterColumn: 'id', filterValue: jobId },
    );
    return () => {
      active = false;
      unsubscribe();
    };
  }

  /** Always creates a DRAFT. Unverified customers may draft (and use the
   * concierge); verification gates publishing, not creating. */
  async createRequest(
    input: CreateRequestInput,
    idempotencyKey: string,
  ): Promise<JobRequest> {
    const pickupPoint = input.pickup.point;
    const destinationPoint = input.destination?.point;
    const id = await this.gateway.rpc('create_request', {
      p_idempotency_key: idempotencyKey,
      p_category_key: input.categoryId,
      p_description: input.description,
      p_pickup_label: input.pickup.label,
      p_urgency: input.urgency ?? 'standard',
      // Sent only when true — false is the server default.
      p_is_custom_category: input.isCustomCategory ? true : undefined,
      p_custom_category_label: input.customCategoryLabel,
      p_pickup_landmark_note: input.pickup.landmarkNote,
      p_pickup_lat: pickupPoint?.latitude,
      p_pickup_lng: pickupPoint?.longitude,
      p_destination_label: input.destination?.label,
      p_destination_landmark_note: input.destination?.landmarkNote,
      p_destination_lat: destinationPoint?.latitude,
      p_destination_lng: destinationPoint?.longitude,
      p_scheduled_at: input.scheduledAt?.toISOString(),
      p_preferred_price_minor: input.preferredPrice?.amountMinor,
      p_item_float_minor: input.itemFloat?.amountMinor,
      p_declared_value_minor: input.declaredValue?.amountMinor,
      // Divergence from the Dart repo (which omits it): the server default is
      // 'app', correct for mobile but wrong for web-created requests.
      p_created_via: 'web',
      p_media_paths:
        input.mediaPaths === undefined || input.mediaPaths.length === 0
          ? undefined
          : input.mediaPaths,
    });
    const created = await loadJobRequestRow(this.gateway, SupabaseGateway.asId(id));
    if (created === null) throw new AppError(ErrorCodes.unknown);
    return created;
  }

  /** Mock-era draft editing — contracts v1 has no update_request RPC (the
   * Dart domain interface dropped the method entirely). */
  async updateDraft(
    _jobId: string,
    _patch: UpdateRequestInput,
    _idempotencyKey: string,
  ): Promise<JobRequest> {
    throw new AppError(ErrorCodes.featureUnavailable);
  }

  async publishRequest(jobId: string, idempotencyKey: string): Promise<JobRequest> {
    return this.mutate('publish_request', jobId, {
      p_idempotency_key: idempotencyKey,
    });
  }

  /** Cancellation is a server decision (fees depend on state and timing). */
  async cancelRequest(
    jobId: string,
    reasonKey: string,
    idempotencyKey: string,
  ): Promise<JobRequest> {
    return this.mutate('cancel_request', jobId, {
      p_idempotency_key: idempotencyKey,
      p_reason_code: reasonKey,
    });
  }

  /** The transition RPCs return the new status scalar; the entity needs the
   * full row, so every mutation re-selects. */
  private async mutate(
    fn: string,
    jobId: string,
    args: Record<string, unknown>,
  ): Promise<JobRequest> {
    await this.gateway.rpc(fn, { p_request_id: jobId, ...args });
    const updated = await loadJobRequestRow(this.gateway, jobId);
    if (updated === null) throw new AppError(ErrorCodes.unknown);
    return updated;
  }
}
