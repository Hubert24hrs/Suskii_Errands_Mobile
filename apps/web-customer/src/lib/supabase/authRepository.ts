// AuthRepository over Supabase Auth (GoTrue) + the `profiles` row (own row
// only — RLS). Phone/email OTP are GoTrue's; Google and Apple are GoTrue's
// OAuth redirect flow (the provider must be enabled with the web client and
// its secret, supabase/deploy/write-remote-config.sh). Mirrors
// packages/suskii_data/lib/src/supabase/supabase_auth_repository.dart.

import { AppError, ErrorCodes } from '@/mocks/errors';
import type { AppUser, AuthState, SocialProvider } from '@/mocks/types';
import type { Unsubscribe } from '@/mocks/repos/base';

import { mapSupabaseError } from './errors';
import type { SupabaseGateway } from './gateway';
import { fetchMyProfile } from './userRepository';

const PENDING_COUNTRY_KEY = 'suskii.pendingCountry';

/** Sign-up metadata `private.handle_new_user` reads: the new profile's
 * country and language. An existing account ignores it. */
export interface SignUpOptions {
  countryCode?: string;
  language?: string;
}

function signUpMetadata(options?: SignUpOptions): Record<string, string> {
  const data: Record<string, string> = {};
  if (options?.countryCode) data['country_code'] = options.countryCode.toUpperCase();
  if (options?.language) data['language'] = options.language;
  return data;
}

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
        .then((user) => this.applyPendingCountry(user))
        .then((user) => onChange({ status: 'signed_in', user }))
        .catch(() => {
          // Profile unreadable (e.g. mid-signup before the row exists): the
          // session is real, the profile is not yet.
          onChange({ status: 'signed_in' });
        });
    });
    return () => subscription.unsubscribe();
  }

  /** A Google or Apple sign-up has no country yet: set the one chosen before
   * the redirect, once. Anything else passes through untouched. */
  private async applyPendingCountry(user: AppUser): Promise<AppUser> {
    if (user.countryCode || typeof window === 'undefined') return user;
    const pending = window.sessionStorage.getItem(PENDING_COUNTRY_KEY);
    if (!pending) return user;
    window.sessionStorage.removeItem(PENDING_COUNTRY_KEY);
    await this.gateway.rpc('set_initial_country', { p_country_code: pending });
    return fetchMyProfile(this.gateway);
  }

  async requestPhoneOtp(phoneE164: string, options?: SignUpOptions): Promise<void> {
    try {
      const { error } = await this.gateway.auth.signInWithOtp({
        phone: phoneE164,
        options: { data: signUpMetadata(options) },
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

  /** Without a country an email sign-up has no profile country at all (there
   * is no phone for the server to read one from), and could never post. */
  async requestEmailOtp(email: string, options?: SignUpOptions): Promise<void> {
    try {
      const { error } = await this.gateway.auth.signInWithOtp({
        email,
        options: { data: signUpMetadata(options) },
      });
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

  /** Leaves the page for Google or Apple; the session arrives when the
   * provider redirects back and supabase-js reads it from the URL. The
   * country waits in sessionStorage, because an OAuth sign-up carries no
   * metadata and the new profile has none until `set_initial_country`. */
  async signInWithProvider(
    provider: SocialProvider,
    options: { countryCode: string; redirectTo: string },
  ): Promise<void> {
    try {
      window.sessionStorage.setItem(PENDING_COUNTRY_KEY, options.countryCode);
      const { error } = await this.gateway.auth.signInWithOAuth({
        provider,
        options: { redirectTo: options.redirectTo },
      });
      if (error) throw error;
    } catch (error) {
      throw mapSupabaseError(error);
    }
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
