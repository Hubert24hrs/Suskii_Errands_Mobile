// UserRepository over Supabase: the caller's own `profiles` row (RLS-scoped)
// merged with the GoTrue identity for phone/email, and `set_active_mode` for
// the customer/provider switch — the server enforces provider KYC
// (ERR_PROVIDER_NOT_VERIFIED). Mirrors
// packages/suskii_data/lib/src/supabase/supabase_user_repository.dart.

import { AppError, ErrorCodes } from '@/mocks/errors';
import type { AppUser, UserMode } from '@/mocks/types';
import type { Unsubscribe } from '@/mocks/repos/base';

import { mapSupabaseError } from './errors';
import type { SupabaseGateway } from './gateway';
import { appUserFromProfileRow, profileRowColumns, userModeFromWire } from './mappers';

/** The caller's own profile merged with the GoTrue identity (phone/email
 * live on the auth user, not on `profiles`). Shared with the auth repo. */
export async function fetchMyProfile(gateway: SupabaseGateway): Promise<AppUser> {
  const {
    data: { user: authUser },
  } = await gateway.auth.getUser();
  if (!authUser) throw new AppError(ErrorCodes.unauthenticated);
  const row = await gateway.selectSingle(
    'profiles',
    profileRowColumns,
    'user_id',
    authUser.id,
  );
  if (!row) throw new AppError(ErrorCodes.unauthenticated);
  return appUserFromProfileRow(row, {
    phoneE164: authUser.phone ?? undefined,
    email: authUser.email ?? undefined,
  });
}

export class SupabaseUserRepository {
  constructor(private readonly gateway: SupabaseGateway) {}

  async getProfile(): Promise<AppUser> {
    return fetchMyProfile(this.gateway);
  }

  /** Emits the current profile immediately, then on every profiles change. */
  watchProfile(onChange: (user: AppUser) => void): Unsubscribe {
    let active = true;
    const emit = async (): Promise<void> => {
      try {
        const user = await fetchMyProfile(this.gateway);
        if (active) onChange(user);
      } catch {
        // Signed out or profile not readable yet; the next event retries.
      }
    };
    void emit();
    let channelSub: Unsubscribe = () => {};
    void this.gateway.currentAuthUserId().then((userId) => {
      if (!active || !userId) return;
      channelSub = this.gateway.watchRows(
        'profiles',
        profileRowColumns,
        () => void emit(),
        { filterColumn: 'user_id', filterValue: userId },
      );
    });
    return () => {
      active = false;
      channelSub();
    };
  }

  async setActiveMode(mode: UserMode, _idempotencyKey: string): Promise<UserMode> {
    // The RPC takes no idempotency key — the mode switch is naturally
    // idempotent (same input, same state).
    try {
      const result = await this.gateway.rpc('set_active_mode', { p_mode: mode });
      return userModeFromWire(result);
    } catch (error) {
      throw mapSupabaseError(error);
    }
  }
}
