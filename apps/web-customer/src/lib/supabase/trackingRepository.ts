// TrackingRepository over Supabase: the provider's app samples its GPS into
// `location_samples` (server-validated, anti-mock flagged); the customer
// side renders the latest sample from the RLS-scoped stream — no Broadcast
// channel needed. Mirrors
// packages/suskii_data/lib/src/supabase/supabase_tracking_repository.dart.

import type { GeoPoint } from '@/mocks/types';
import type { Unsubscribe } from '@/mocks/repos/base';

import type { SupabaseGateway } from './gateway';
import { geoPointFromWire } from './mappers';

export class SupabaseTrackingRepository {
  constructor(private readonly gateway: SupabaseGateway) {}

  /** Emits the latest provider sample for the job when one exists, then on
   * every new sample. Emits nothing while the job has no samples yet (same
   * as the Dart impl, which filters null points out of the stream). */
  watchProviderLocation(
    jobId: string,
    onChange: (point: GeoPoint) => void,
  ): Unsubscribe {
    return this.gateway.watchRows(
      'location_samples',
      'id, pos, recorded_at',
      (rows) => {
        const latest = rows
          .slice()
          .sort((a, b) =>
            String(a['recorded_at']).localeCompare(String(b['recorded_at'])),
          )
          .at(-1);
        const point =
          latest === undefined ? undefined : geoPointFromWire(latest['pos']);
        if (point !== undefined) onChange(point);
      },
      {
        column: 'request_id',
        value: jobId,
        filterColumn: 'request_id',
        filterValue: jobId,
      },
    );
  }
}
