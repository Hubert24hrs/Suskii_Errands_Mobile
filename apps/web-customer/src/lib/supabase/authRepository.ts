// AuthRepository over Supabase Auth (GoTrue) + the `profiles` row (own row
// only — RLS). Phone/email OTP are GoTrue's; social providers stay
// unavailable until vendor accounts exist. Mirrors
// packages/suskii_data/lib/src/supabase/supabase_auth_repository.dart.

import { AppError, ErrorCodes } from '@/mocks/errors';
import type { AppUser, AuthState } from '@/mocks/types';
import type { Unsubscribe } from '@/mocks/repos/base';

import { mapSupabaseError } from './errors';
import type { SupabaseGateway } from './gateway';
import { fetchMyProfile } from './userRepository';

export class SupabaseAuthRepository {
  constructor(private readonly gateway: SupabaseGateway) {}

  /** Emits the current state immediately (INITIAL_SESSION), then on every
   * GoTrue auth event. */
  authStateChanges(onChange: (state: AuthState) => void): Unsubscribe {
    const {
      data: { subscription },
    } = this.gateway.auth.onAuthStateChange((event, session) => {
      if (!session || event === 'SIGNED_OUT') {
        onChange({ status: 'signed_out' });
        return;
      }
      void fetchMyProfile(this.gateway)
        .then((user) => onChange({ status: 'signed_in', user }))
        .catch(() => {
          // Profile unreadable (e.g. mid-signup before the row exists): the
          // session is real, the profile is not yet.
          onChange({ status: 'signed_in' });
        });
    });
    return () => subscription.unsubscribe();
  }

  async requestPhoneOtp(phoneE164: string): Promise<void> {
    try {
      const { error } = await this.gateway.auth.signInWithOtp({
        phone: phoneE164,
      });
      if (error) throw error;
    } catch (error) {
      throw mapSupabaseError(error);
    }
  }

  async verifyPhoneOtp(phoneE164: string, code: string): Promise<AppUser> {
    try {
      const { error } = await this.gateway.auth.verifyOtp({
        type: 'sms',
        phone: phoneE164,
        token: code,
      });
      if (error) throw error;
    } catch (error) {
      throw mapSupabaseError(error);
    }
    return fetchMyProfile(this.gateway);
  }

  async requestEmailOtp(email: string): Promise<void> {
    try {
      const { error } = await this.gateway.auth.signInWithOtp({ email });
      if (error) throw error;
    } catch (error) {
      throw mapSupabaseError(error);
    }
  }

  async verifyEmailOtp(email: string, code: string): Promise<AppUser> {
    try {
      const { error } = await this.gateway.auth.verifyOtp({
        type: 'email',
        email,
        token: code,
      });
      if (error) throw error;
    } catch (error) {
      throw mapSupabaseError(error);
    }
    return fetchMyProfile(this.gateway);
  }

  async signInWithGoogle(): Promise<AppUser> {
    throw new AppError(ErrorCodes.featureUnavailable);
  }

  async signInWithApple(): Promise<AppUser> {
    throw new AppError(ErrorCodes.featureUnavailable);
  }

  async signOut(): Promise<void> {
    try {
      const { error } = await this.gateway.auth.signOut();
      if (error) throw error;
    } catch (error) {
      throw mapSupabaseError(error);
    }
  }

  /** Mock-only demo hook; no backend equivalent. */
  switchPersona(_userId: string): AppUser {
    throw new AppError(ErrorCodes.featureUnavailable);
  }
}
