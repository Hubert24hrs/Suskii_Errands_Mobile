// Shared plumbing for the admin console's Supabase repositories: the gateway, the
// step-up window for sensitive actions, and name lookups.
//
// Authorisation is the server's: every admin function re-reads `admin_users` and
// requires aal2, and the five sensitive ones also refuse a TOTP code older than five
// minutes (`private.require_recent_mfa`, audit Z.11). The check here asks first, so
// the code is requested before the call rather than after a refusal; a refusal from
// the server lands in the same modal either way.

import { AppError, ErrorCodes } from '@/mocks/errors';
import type { AdminRole, Money } from '@/mocks/types';

import { SupabaseGateway, type Row } from './gateway';

export const REAUTH_WINDOW_MS = 5 * 60_000;

const ROLE_ORDER: readonly AdminRole[] = [
  'super_admin',
  'finance_officer',
  'dispute_officer',
  'verification_officer',
  'support_agent',
];

/** The role claim the access-token hook adds (admin_roles), validated. */
export function parseRoles(value: unknown): AdminRole[] {
  if (!Array.isArray(value)) return [];
  return ROLE_ORDER.filter((r) => value.includes(r));
}

export function primaryRole(roles: readonly AdminRole[]): AdminRole {
  return roles[0] ?? 'support_agent';
}

/** When a TOTP code was last verified in this session (ms), from the signed `amr` claim. */
export function lastTotpMs(methods: ReadonlyArray<string | { method: string; timestamp: number }>): number {
  return Math.max(
    0,
    ...methods
      .filter((m): m is { method: string; timestamp: number } => typeof m !== 'string')
      .filter((m) => m.method === 'totp')
      .map((m) => m.timestamp * 1000),
  );
}

export function money(amountMinor: unknown, currency: unknown): Money {
  return {
    amountMinor: SupabaseGateway.asMinorUnits(amountMinor ?? 0),
    currency: String(currency ?? ''),
  };
}

export abstract class SupabaseAdminRepo {
  constructor(protected readonly gw: SupabaseGateway) {}

  protected async selfId(): Promise<string> {
    const {
      data: { session },
    } = await this.gw.auth.getSession();
    if (!session) throw new AppError(ErrorCodes.unauthenticated);
    return session.user.id;
  }

  /** ERR_REAUTH_REQUIRED unless a TOTP code was verified in the last five minutes. */
  protected async requireRecentMfa(action: string): Promise<void> {
    const { data, error } = await this.gw.auth.mfa.getAuthenticatorAssuranceLevel();
    if (error || !data) throw new AppError(ErrorCodes.unauthenticated);
    if (data.currentLevel !== 'aal2') throw new AppError(ErrorCodes.sessionExpired);
    if (Date.now() - lastTotpMs(data.currentAuthenticationMethods) > REAUTH_WINDOW_MS) {
      throw new AppError(ErrorCodes.reauthRequired, { details: { action } });
    }
  }

  /** Display names for user ids the caller may read (RLS scopes them). */
  protected async names(ids: Iterable<unknown>): Promise<Map<string, string>> {
    const unique = [...new Set([...ids].filter((id) => id !== null && id !== undefined))].map(
      String,
    );
    const map = new Map<string, string>();
    if (unique.length === 0) return map;
    const rows = await this.gw.selectList('profiles', 'user_id, display_name', {
      inColumn: 'user_id',
      inValues: unique,
    });
    for (const row of rows) {
      const name = row['display_name'];
      if (typeof name === 'string' && name.trim() !== '') map.set(String(row['user_id']), name);
    }
    return map;
  }

  /** A name, or a short form of the id when the profile is out of the caller's scope. */
  protected static nameOf(names: Map<string, string>, id: unknown): string {
    if (id === null || id === undefined) return '—';
    return names.get(String(id)) ?? `${String(id).slice(0, 8)}…`;
  }

  protected static first(rows: Row[]): Row {
    const row = rows[0];
    if (!row) throw new AppError(ErrorCodes.notFound);
    return row;
  }
}
