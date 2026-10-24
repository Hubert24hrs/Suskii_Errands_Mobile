// Provider mode over Supabase, the same contract functions the mobile app
// calls (packages/suskii_data/lib/src/supabase/supabase_provider_repository.dart,
// supabase_job_progress_repository.dart, supabase_media_upload_repository.dart):
// the open-requests feed is `provider_feed` (approximate places only — the
// exact pickup is shown after funding), offers are `create_offer`, the online
// toggle is `set_online`, and job execution is `set_job_status`, `verify_pin`
// and `submit_proof`. The server owns every state machine.

import { AppError, ErrorCodes } from '@/mocks/errors';
import type { Unsubscribe } from '@/mocks/repos/base';
import {
  isTerminalJobStatus,
  type DocumentExpiryWarning,
  type GeoPoint,
  type HandoverPinKind,
  type JobRequest,
  type JobStatus,
  type Money,
  type Offer,
  type PinVerificationResult,
  type Proof,
  type ProofKind,
  type ProviderHomeSummary,
  type UploadBucket,
} from '@/mocks/types';

import { SupabaseGateway, type Row } from './gateway';
import {
  jobRequestFromRow,
  jobStatusFromWire,
  offerFromRow,
  urgencyFromWire,
  verificationFromWire,
} from './mappers';
import { loadJobRequestRow, requestRowColumns } from './requestRepository';
import { providerLocationEvent } from './trackingRepository';

const offerColumns =
  'id, thread_id, request_id, provider_id, author_side, amount_minor, ' +
  'currency, message, status, round, expires_at, created_at';

const proofColumns =
  'id, request_id, uploaded_by, kind, storage_path, device_point, ' +
  'device_captured_at, server_received_at';

function moneyOrUndefined(value: unknown, currency: string): Money | undefined {
  return value == null ? undefined : { amountMinor: SupabaseGateway.asMinorUnits(value), currency };
}

/** A `provider_home_summary` row (contracts 2.0.0). */
export function providerHomeSummaryFromRow(row: Row): ProviderHomeSummary {
  const currency = (row['currency'] as string | null) ?? 'NGN';
  const warnings = Array.isArray(row['document_warnings']) ? (row['document_warnings'] as Row[]) : [];
  return {
    online: row['online'] === true,
    verificationStatus: verificationFromWire(row['verification_status']),
    todayEarnings: {
      amountMinor: SupabaseGateway.asMinorUnits(row['today_earnings_minor'] ?? 0),
      currency,
    },
    completedToday: Number(row['completed_today'] ?? 0),
    nearbyOpenRequests: Number(row['nearby_open_requests'] ?? 0),
    documentWarnings: warnings
      .filter((w) => typeof w === 'object' && w !== null)
      .map(
        (w): DocumentExpiryWarning => ({
          documentTypeKey: (w['document_type_key'] as string | null) ?? '',
          daysRemaining: Number(w['days_remaining'] ?? 0),
        }),
      ),
  };
}

/** A `provider_feed` row: an area label and an approximate point, never the exact pickup. */
export function jobRequestFromFeedRow(row: Row): JobRequest {
  const currency = (row['currency'] as string | null) ?? 'NGN';
  const isCustom = row['is_custom_category'] === true;
  const approx = (lat: unknown, lng: unknown): GeoPoint | undefined =>
    typeof lat === 'number' && typeof lng === 'number' ? { latitude: lat, longitude: lng } : undefined;
  return {
    id: SupabaseGateway.asId(row['request_id']),
    customerId: '',
    categoryId: isCustom ? 'custom' : ((row['category_key'] as string | null) ?? 'custom'),
    isCustomCategory: isCustom,
    description: (row['description'] as string | null) ?? '',
    mediaPaths: Array.isArray(row['media_paths']) ? (row['media_paths'] as string[]) : [],
    pickup: {
      label: (row['pickup_area'] as string | null) ?? '',
      point: approx(row['pickup_approx_lat'], row['pickup_approx_lng']),
    },
    destination:
      row['has_destination'] === true
        ? { label: '', point: approx(row['destination_approx_lat'], row['destination_approx_lng']) }
        : undefined,
    urgency: urgencyFromWire(row['urgency']),
    status: 'published',
    createdAt: SupabaseGateway.asTimestamp(row['created_at']),
    scheduledAt: row['scheduled_at'] == null ? undefined : SupabaseGateway.asTimestamp(row['scheduled_at']),
    preferredPrice: moneyOrUndefined(row['preferred_price_minor'], currency),
    itemFloat: moneyOrUndefined(row['item_float_minor'], currency),
  };
}

/** A `proofs` row. */
export function proofFromRow(row: Row): Proof {
  const kind = row['kind'];
  return {
    id: SupabaseGateway.asId(row['id']),
    jobId: SupabaseGateway.asId(row['request_id']),
    providerId: SupabaseGateway.asId(row['uploaded_by']),
    kind: kind === 'receipt' || kind === 'signature' ? kind : 'photo',
    storagePath: (row['storage_path'] as string | null) ?? '',
    createdAt: SupabaseGateway.asTimestamp(row['server_received_at']),
    capturedAt:
      row['device_captured_at'] == null ? undefined : SupabaseGateway.asTimestamp(row['device_captured_at']),
  };
}

export class SupabaseProviderRepository {
  constructor(private readonly gateway: SupabaseGateway) {}

  /** One call: online, standing, today's earnings and jobs, open requests nearby, expiring documents. */
  async getHomeSummary(): Promise<ProviderHomeSummary> {
    const rows = (await this.gateway.rpc('provider_home_summary')) as Row[];
    if (rows.length === 0) throw new AppError(ErrorCodes.unknown);
    return providerHomeSummaryFromRow(rows[0]);
  }

  /** `provider_feed` is one-shot; it re-runs when a notification reaches the provider (a match
   * is one) and on the refresh timer. */
  watchNearbyRequests(onChange: (requests: JobRequest[]) => void): Unsubscribe {
    let running = false;
    let dirty = false;
    let active = true;
    const refresh = async (): Promise<void> => {
      if (running) {
        dirty = true;
        return;
      }
      running = true;
      try {
        const rows = (await this.gateway.rpc('provider_feed')) as Row[];
        if (active) onChange(rows.map(jobRequestFromFeedRow));
      } catch {
        // The next tick retries.
      } finally {
        running = false;
        if (dirty) {
          dirty = false;
          void refresh();
        }
      }
    };
    let unsubscribe: Unsubscribe = () => {};
    void this.gateway.currentAuthUserId().then((me) => {
      if (!active || !me) return;
      unsubscribe = this.gateway.refreshes(refresh, { topics: [`user:${me}`], everyMs: 30_000 });
    });
    return () => {
      active = false;
      unsubscribe();
    };
  }

  /** The provider's own offers: the display card is the caller's, so no `get_provider_card`. */
  async getMyOffers(): Promise<Offer[]> {
    const me = await this.gateway.currentAuthUserId();
    if (!me) throw new AppError(ErrorCodes.unauthenticated);
    const rows = await this.gateway.selectList('offers', offerColumns, {
      column: 'provider_id',
      value: me,
      orderBy: 'created_at',
      ascending: false,
    });
    return rows.map((row) => offerFromRow(row));
  }

  watchMyJobs(onChange: (jobs: JobRequest[]) => void): Unsubscribe {
    let active = true;
    let unsubscribe: Unsubscribe = () => {};
    void this.gateway.currentAuthUserId().then((me) => {
      if (!me || !active) return;
      unsubscribe = this.gateway.watchRows(
        'jobs',
        'request_id',
        (rows) => {
          void Promise.all(
            rows.map((row) => loadJobRequestRow(this.gateway, SupabaseGateway.asId(row['request_id']))),
          ).then((jobs) => {
            if (!active) return;
            onChange(
              jobs
                .filter((j): j is JobRequest => j !== null && !isTerminalJobStatus(j.status))
                .sort((a, b) => b.createdAt.getTime() - a.createdAt.getTime()),
            );
          });
        },
        // A job's status lives on its request, so every tick reloads them.
        { column: 'provider_id', value: me, filterColumn: 'provider_id', filterValue: me, topics: [`user:${me}`], distinct: false },
      );
    });
    return () => {
      active = false;
      unsubscribe();
    };
  }

  async getMyJobsHistory(limit = 20): Promise<JobRequest[]> {
    const me = await this.gateway.currentAuthUserId();
    if (!me) throw new AppError(ErrorCodes.unauthenticated);
    const jobs = await this.gateway.selectList('jobs', 'request_id', { column: 'provider_id', value: me });
    if (jobs.length === 0) return [];
    const rows = await this.gateway.selectList('requests', requestRowColumns, {
      inColumn: 'id',
      inValues: jobs.map((row) => SupabaseGateway.asId(row['request_id'])),
      orderBy: 'created_at',
      ascending: false,
    });
    return rows
      .map((row) => jobRequestFromRow(row))
      .filter((request) => isTerminalJobStatus(request.status))
      .slice(0, limit);
  }

  async submitOffer(options: {
    requestId: string;
    amount: Money;
    idempotencyKey: string;
    message?: string;
  }): Promise<Offer> {
    const id = await this.gateway.rpc('create_offer', {
      p_idempotency_key: options.idempotencyKey,
      p_request_id: options.requestId,
      p_amount_minor: options.amount.amountMinor,
      p_message: options.message,
    });
    const row = await this.gateway.selectSingle('offers', offerColumns, 'id', SupabaseGateway.asId(id));
    if (row === null) throw new AppError(ErrorCodes.unknown);
    return offerFromRow(row);
  }

  /**
   * An online provider between jobs: the heartbeat alone. Matching only
   * considers a position younger than two minutes.
   */
  async reportPosition(point: GeoPoint, accuracyMetres?: number): Promise<void> {
    await this.gateway.rpc('heartbeat', {
      p_lat: point.latitude,
      p_lng: point.longitude,
      p_accuracy_m: accuracyMetres === undefined ? undefined : Math.round(accuracyMetres),
      p_is_mock: false,
    });
  }

  /** A plain state toggle: `set_online` takes no idempotency key and replays as itself. */
  async setOnline(online: boolean, _idempotencyKey: string): Promise<boolean> {
    return (await this.gateway.rpc('set_online', { p_online: online })) as boolean;
  }
}

export class SupabaseProviderJobRepository {
  constructor(private readonly gateway: SupabaseGateway) {}

  private lastHeartbeat = 0;

  private async reload(jobId: string): Promise<JobRequest> {
    const updated = await loadJobRequestRow(this.gateway, jobId);
    if (updated === null) throw new AppError(ErrorCodes.unknown);
    return updated;
  }

  /** ARRIVED is checked against the pickup geofence: a location, or a reason for a manual arrival. */
  async requestStatusChange(
    jobId: string,
    target: JobStatus,
    options: { idempotencyKey: string; location?: GeoPoint; reasonCode?: string },
  ): Promise<JobRequest> {
    await this.gateway.rpc('set_job_status', {
      p_idempotency_key: options.idempotencyKey,
      p_request_id: jobId,
      p_target: target,
      p_reason_code: options.reasonCode,
      p_lat: options.location?.latitude,
      p_lng: options.location?.longitude,
    });
    return this.reload(jobId);
  }

  /** A wrong PIN is a result (the attempt counter must survive); the exhausted case raises. */
  async verifyHandoverPin(
    jobId: string,
    pin: string,
    kind: HandoverPinKind,
    idempotencyKey: string,
  ): Promise<PinVerificationResult> {
    const result = (await this.gateway.rpc('verify_pin', {
      p_idempotency_key: idempotencyKey,
      p_request_id: jobId,
      p_pin: pin,
      p_kind: kind,
    })) as Row;
    return {
      verified: result['verified'] === true,
      status: jobStatusFromWire(result['status']),
      attemptsRemaining: Number(result['attempts_remaining'] ?? 0),
    };
  }

  async submitProof(options: {
    jobId: string;
    kind: ProofKind;
    storagePath: string;
    idempotencyKey: string;
    capturedAt?: Date;
    location?: GeoPoint;
  }): Promise<Proof> {
    const id = await this.gateway.rpc('submit_proof', {
      p_idempotency_key: options.idempotencyKey,
      p_request_id: options.jobId,
      p_kind: options.kind,
      p_storage_path: options.storagePath,
      p_device_captured_at: options.capturedAt?.toISOString(),
      p_lat: options.location?.latitude,
      p_lng: options.location?.longitude,
    });
    const row = await this.gateway.selectSingle('proofs', proofColumns, 'id', SupabaseGateway.asId(id));
    if (row === null) throw new AppError(ErrorCodes.unknown);
    return proofFromRow(row);
  }

  async getProofs(jobId: string): Promise<Proof[]> {
    const rows = await this.gateway.selectList('proofs', proofColumns, {
      column: 'request_id',
      value: jobId,
      orderBy: 'server_received_at',
    });
    return rows.map(proofFromRow);
  }

  /**
   * The customer's map listens on the job's channel (ADR-0009); a heartbeat at
   * most every 30 s keeps matching and the trip trail current. A lost ping is
   * replaced by the next one.
   */
  async publishProviderLocation(jobId: string, point: GeoPoint, accuracyMetres?: number): Promise<void> {
    try {
      await this.gateway.sendBroadcast(`job:${jobId}`, providerLocationEvent, {
        lat: point.latitude,
        lng: point.longitude,
        accuracy_m: accuracyMetres,
        is_mock: false,
        at: new Date().toISOString(),
      });
    } catch {
      // Dropped ping; the heartbeat below still runs.
    }
    const now = Date.now();
    if (now - this.lastHeartbeat >= 30_000) {
      this.lastHeartbeat = now;
      await this.gateway.rpc('heartbeat', {
        p_lat: point.latitude,
        p_lng: point.longitude,
        p_accuracy_m: accuracyMetres === undefined ? undefined : Math.round(accuracyMetres),
        p_is_mock: false,
      });
    }
  }
}

const extensions: Record<string, string> = {
  'image/jpeg': 'jpg',
  'image/png': 'png',
  'image/webp': 'webp',
  'image/heic': 'heic',
  'application/pdf': 'pdf',
};

/** Storage uploads, the path built the way each bucket policy reads it; the file name is random. */
export class SupabaseMediaUploadRepository {
  constructor(private readonly gateway: SupabaseGateway) {}

  async upload(options: { bucket: UploadBucket; file: Blob; requestId?: string }): Promise<string> {
    if (options.file.size === 0) throw new AppError(ErrorCodes.invalidArgument);
    const me = await this.gateway.currentAuthUserId();
    if (!me) throw new AppError(ErrorCodes.unauthenticated);
    const jobScoped = options.bucket === 'job-proofs' || options.bucket === 'receipts';
    if (jobScoped && !options.requestId) throw new AppError(ErrorCodes.invalidArgument);
    const folder = jobScoped ? options.requestId! : me;
    const bytes = crypto.getRandomValues(new Uint8Array(16));
    const name = Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
    const contentType = options.file.type || 'application/octet-stream';
    const path = `${folder}/${name}.${extensions[contentType] ?? 'bin'}`;
    await this.gateway.uploadBinary(options.bucket, path, options.file, contentType);
    return path;
  }
}
