// SafetyRepository over Supabase: `raise_sos` creates the incident
// server-side (ops, security partner and trusted contacts are notified
// there); the client renders the alert state from the RLS-scoped
// `sos_incidents` table. Mirrors
// packages/suskii_data/lib/src/supabase/supabase_safety_repository.dart.

import { AppError, ErrorCodes } from '@/mocks/errors';
import type { GeoPoint, SosAlert, TripShare } from '@/mocks/types';
import type { Unsubscribe } from '@/mocks/repos/base';

import { SupabaseGateway } from './gateway';
import { sosAlertFromRow } from './mappers';

const sosColumns =
  'id, request_id, raised_by, point, status, trusted_contacts_notified, ' +
  'created_at, resolved_at';

export class SupabaseSafetyRepository {
  constructor(private readonly gateway: SupabaseGateway) {}

  /** SOS is naturally idempotent: a second trigger while one is active
   * returns the same incident (server-side). */
  async triggerSos(options: {
    jobId: string;
    idempotencyKey: string;
    location?: GeoPoint;
  }): Promise<SosAlert> {
    const id = await this.gateway.rpc('raise_sos', {
      p_idempotency_key: options.idempotencyKey,
      p_request_id: options.jobId,
      p_lat: options.location?.latitude,
      p_lng: options.location?.longitude,
    });
    const row = await this.gateway.selectSingle(
      'sos_incidents',
      sosColumns,
      'id',
      SupabaseGateway.asId(id),
    );
    if (row === null) throw new AppError(ErrorCodes.unknown);
    return sosAlertFromRow(row);
  }

  /** Emits the latest alert for the job when it is active (else undefined)
   * immediately, then on every change. */
  watchActiveSos(
    jobId: string,
    onChange: (alert: SosAlert | undefined) => void,
  ): Unsubscribe {
    return this.gateway.watchRows(
      'sos_incidents',
      sosColumns,
      (rows) => {
        const latestRow = rows
          .slice()
          .sort((a, b) =>
            String(a['created_at']).localeCompare(String(b['created_at'])),
          )
          .at(-1);
        if (latestRow === undefined) {
          onChange(undefined);
          return;
        }
        const alert = sosAlertFromRow(latestRow);
        onChange(alert.status === 'active' ? alert : undefined);
      },
      {
        column: 'request_id',
        value: jobId,
        filterColumn: 'request_id',
        filterValue: jobId,
      },
    );
  }

  async createTripShareLink(jobId: string, idempotencyKey: string): Promise<TripShare> {
    // The RPC returns the raw share TOKEN only — the URL base and the
    // server-config TTL are server-side knowledge the contract does not hand
    // out yet (CR-20260923-01). PROVISIONAL: the token rides in `url` and
    // the expiry assumes the documented default TTL (60 min, remote_config
    // trip_share_ttl_minutes) until the CR lands.
    const token = await this.gateway.rpc('create_trip_share', {
      p_idempotency_key: idempotencyKey,
      p_request_id: jobId,
    });
    return {
      url: token as string,
      expiresAt: new Date(Date.now() + 60 * 60_000),
    };
  }
}
