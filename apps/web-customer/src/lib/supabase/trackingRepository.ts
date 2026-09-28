// TrackingRepository over Supabase, as ADR-0009 designs it: the provider's app
// broadcasts its position on the job's private Realtime channel
// (`provider.location` on `job:{id}`, contracts v1.3.0 client-events.json),
// and the customer's map listens. It does not read `location_samples`: the RLS
// matrix gives participants the trail only after the job ends, so reading it
// during a job showed nothing (audit 2026-09-27 Y.31). Mirrors
// packages/suskii_data/lib/src/supabase/supabase_tracking_repository.dart.

import type { GeoPoint } from '@/mocks/types';
import type { Unsubscribe } from '@/mocks/repos/base';

import type { SupabaseGateway } from './gateway';

export const providerLocationEvent = 'provider.location';

/** A payload's position, or undefined when it is not a valid one. */
export function pointFromLocationPayload(
  payload: Record<string, unknown>,
): GeoPoint | undefined {
  const { lat, lng } = payload;
  if (typeof lat !== 'number' || typeof lng !== 'number') return undefined;
  if (lat < -90 || lat > 90 || lng < -180 || lng > 180) return undefined;
  return { latitude: lat, longitude: lng };
}

export class SupabaseTrackingRepository {
  constructor(private readonly gateway: SupabaseGateway) {}

  /** Emits each position the provider broadcasts; nothing until the first. */
  watchProviderLocation(
    jobId: string,
    onChange: (point: GeoPoint) => void,
  ): Unsubscribe {
    return this.gateway.watchBroadcast(`job:${jobId}`, providerLocationEvent, (payload) => {
      const point = pointFromLocationPayload(payload);
      if (point !== undefined) onChange(point);
    });
  }
}
