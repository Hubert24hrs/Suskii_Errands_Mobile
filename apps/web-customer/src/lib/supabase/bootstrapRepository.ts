// BootstrapRepository over Supabase: the cold-start payload from the
// `get_bootstrap` RPC (anon-callable, so the pre-login country picker works)
// plus the unread-notification count, and live notifications from the
// `notifications` table (RLS scopes rows to the signed-in user). Mirrors
// packages/suskii_data/lib/src/supabase/supabase_bootstrap_repository.dart.

import { syncServerClock } from '@/lib/serverClock';
import { AppError, ErrorCodes } from '@/mocks/errors';
import type { AppBootstrap, AppNotification } from '@/mocks/types';
import type { Unsubscribe } from '@/mocks/repos/base';

import { SupabaseGateway, type Row } from './gateway';
import {
  appNotificationFromRow,
  appUserFromProfileRow,
  countryPackFromBootstrap,
} from './mappers';

/** Explicit column list — a `*` naming an ungranted column fails the query. */
const notificationColumns =
  'id, kind, title_key, body_key, read_at, created_at, deep_link';

/** `feature_flags` / `remote_config.voice_languages` are jsonb key → bool. */
function boolRecord(value: unknown): Record<string, boolean> {
  const out: Record<string, boolean> = {};
  if (value !== null && typeof value === 'object' && !Array.isArray(value)) {
    for (const [key, v] of Object.entries(value as Row)) out[key] = v === true;
  }
  return out;
}

export class SupabaseBootstrapRepository {
  constructor(private readonly gateway: SupabaseGateway) {}

  async getBootstrap(): Promise<AppBootstrap> {
    const payload = (await this.gateway.rpc('get_bootstrap')) as Row;
    const config = (payload['remote_config'] as Row | null) ?? {};
    const packMap = payload['country_pack'] as Row | null;
    if (packMap == null) {
      // No beta/live country for the caller's profile or hint.
      throw new AppError(ErrorCodes.countryDisabled);
    }
    const cities = await this.gateway.selectList('cities', 'name', {
      column: 'country_code',
      value: packMap['code'] as string,
    });
    const userMap = payload['user'] as Row | null;
    const serverTime = SupabaseGateway.asTimestamp(payload['server_time']);
    // Feed the simulated server clock — every TTL renders against it. The
    // mock bootstrap does the same and no screen syncs the clock itself.
    syncServerClock(serverTime);
    return {
      countryPack: countryPackFromBootstrap(
        packMap,
        cities.map((row) => row['name'] as string),
      ),
      featureFlags: boolRecord(payload['feature_flags']),
      voiceLanguages: boolRecord(config['voice_languages']),
      minSupportedAppVersion:
        (payload['min_supported_app_version'] as string | null) ?? '0.0.0',
      unreadNotifications: await this.gateway.countRows('notifications', {
        isNullColumn: 'read_at',
      }),
      serverTime,
      user: userMap == null ? undefined : appUserFromProfileRow(userMap),
      // No server source yet for the active-job banner without an N+1 over
      // requests (HANDOFF M9.1 follow-up: candidate change request for an
      // active_job_banner field in get_bootstrap) — the banner stays absent.
    };
  }

  /** Emits each current notification immediately, then every change. */
  watchNotifications(
    onChange: (notification: AppNotification) => void,
  ): Unsubscribe {
    return this.gateway.watchRows('notifications', notificationColumns, (rows) => {
      for (const row of rows) onChange(appNotificationFromRow(row));
    });
  }
}
