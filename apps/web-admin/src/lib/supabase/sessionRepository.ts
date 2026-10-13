// Admin sign-in against Supabase Auth: password, then a TOTP second factor.
// Every admin function requires aal2 (private.has_admin_role), so a session that
// stops at the password can do nothing; enrolment happens on the first sign-in.

import { AppError, ErrorCodes } from '@/mocks/errors';
import type { SignedInAdmin } from '@/mocks/repositories';
import type { AdminSession, AdminUser, CountryMetrics } from '@/mocks/types';

import { SupabaseAdminRepo, lastTotpMs, money, parseRoles, primaryRole } from './base';
import { mapSupabaseError } from './errors';
import { SupabaseGateway } from './gateway';

/** Shown once, at enrolment: the QR code as an SVG data URI, and the secret for manual entry. */
export interface TotpEnrolment {
  qrCode: string;
  secret: string;
}

export class SupabaseSessionRepository extends SupabaseAdminRepo {
  private pendingFactorId: string | null = null;

  async signIn(
    email: string,
    password: string,
  ): Promise<{ mfaRequired: true; enrolment?: TotpEnrolment }> {
    const { error } = await this.gw.auth.signInWithPassword({ email: email.trim(), password });
    if (error) throw mapSupabaseError(error);

    // The claim is a hint (the server re-reads admin_users); it is enough to stop a
    // customer account at the door rather than after an enrolment it cannot use.
    if (parseRoles((await this.gw.claims())?.['admin_roles']).length === 0) {
      await this.gw.auth.signOut();
      throw new AppError(ErrorCodes.permissionDenied);
    }

    const factors = await this.gw.auth.mfa.listFactors();
    if (factors.error) throw mapSupabaseError(factors.error);
    const verified = factors.data.totp.find((f) => f.status === 'verified');
    if (verified) {
      this.pendingFactorId = verified.id;
      return { mfaRequired: true };
    }

    // An abandoned enrolment blocks a new one with the same name; it was never usable.
    for (const factor of factors.data.all) {
      if (factor.factor_type === 'totp' && factor.status !== 'verified') {
        await this.gw.auth.mfa.unenroll({ factorId: factor.id });
      }
    }
    const enrolled = await this.gw.auth.mfa.enroll({
      factorType: 'totp',
      friendlyName: 'Suskii Admin',
    });
    if (enrolled.error) throw mapSupabaseError(enrolled.error);
    this.pendingFactorId = enrolled.data.id;
    return {
      mfaRequired: true,
      enrolment: { qrCode: enrolled.data.totp.qr_code, secret: enrolled.data.totp.secret },
    };
  }

  async verifyMfa(code: string): Promise<SignedInAdmin> {
    if (!/^\d{6}$/.test(code.trim())) throw new AppError(ErrorCodes.mfaInvalid);
    const factorId = this.pendingFactorId ?? (await this.anyTotpFactorId());
    if (!factorId) throw new AppError(ErrorCodes.invalidState);
    const { error } = await this.gw.auth.mfa.challengeAndVerify({ factorId, code: code.trim() });
    if (error) throw mapSupabaseError(error);
    this.pendingFactorId = null;
    const signedIn = await this.getSession();
    if (!signedIn) throw new AppError(ErrorCodes.unauthenticated);
    return signedIn;
  }

  /** The signed-in admin at aal2, or null (signed out, or the second factor not yet passed). */
  async getSession(): Promise<SignedInAdmin | null> {
    const {
      data: { session },
    } = await this.gw.auth.getSession();
    if (!session) return null;
    const aal = await this.gw.auth.mfa.getAuthenticatorAssuranceLevel();
    if (aal.error || aal.data?.currentLevel !== 'aal2') return null;
    const roles = parseRoles((await this.gw.claims())?.['admin_roles']);
    if (roles.length === 0) return null;

    const user = session.user;
    const profile = await this.gw
      .selectSingle('profiles', 'display_name', 'user_id', user.id)
      .catch(() => null);
    const displayName = profile?.['display_name'];
    const lastTotp = lastTotpMs(aal.data.currentAuthenticationMethods);
    const admin: AdminUser = {
      id: user.id,
      name: typeof displayName === 'string' && displayName.trim() !== ''
        ? displayName
        : (user.email ?? user.id),
      email: user.email ?? '',
      role: primaryRole(roles),
      roles,
      mfaEnrolled: true,
      active: true,
      createdAt: new Date(user.created_at),
      lastSignInAt: user.last_sign_in_at ? new Date(user.last_sign_in_at) : undefined,
    };
    const adminSession: AdminSession = {
      adminId: user.id,
      expiresAt: new Date((session.expires_at ?? 0) * 1000),
      reauthenticatedAt: lastTotp > 0 ? new Date(lastTotp) : undefined,
    };
    return { admin, session: adminSession };
  }

  /** Step-up: verifies a fresh authenticator code, which renews the TOTP timestamp. */
  async reauth(_purpose: string, code?: string): Promise<AdminSession> {
    if (!code || !/^\d{6}$/.test(code.trim())) throw new AppError(ErrorCodes.mfaInvalid);
    const factorId = await this.anyTotpFactorId(true);
    if (!factorId) throw new AppError(ErrorCodes.mfaRequired);
    const { error } = await this.gw.auth.mfa.challengeAndVerify({ factorId, code: code.trim() });
    if (error) throw mapSupabaseError(error);
    const signedIn = await this.getSession();
    if (!signedIn) throw new AppError(ErrorCodes.sessionExpired);
    return signedIn.session;
  }

  async signOut(): Promise<void> {
    this.pendingFactorId = null;
    await this.gw.auth.signOut();
  }

  /** The demo persona switcher has no meaning against real accounts. */
  async switchPersona(_adminId: string): Promise<SignedInAdmin> {
    throw new AppError(ErrorCodes.featureUnavailable);
  }

  private async anyTotpFactorId(verifiedOnly = false): Promise<string | null> {
    const { data, error } = await this.gw.auth.mfa.listFactors();
    if (error) throw mapSupabaseError(error);
    const factor = verifiedOnly
      ? data.totp.find((f) => f.status === 'verified')
      : (data.totp.find((f) => f.status === 'verified') ??
        data.all.find((f) => f.factor_type === 'totp'));
    return factor?.id ?? null;
  }
}

export class SupabaseMetricsRepository extends SupabaseAdminRepo {
  async getOverview(): Promise<CountryMetrics[]> {
    const rows = await this.gw.rpcRows('admin_overview');
    return rows.map((row) => ({
      country: String(row['country_code']),
      currency: String(row['currency']),
      dau: Number(row['active_users'] ?? 0),
      activeJobs: Number(row['active_jobs'] ?? 0),
      offersPerRequest:
        row['offers_per_request'] === null ? 0 : SupabaseGateway.asDecimal(row['offers_per_request']),
      gmv: row['gmv_30d_minor'] === null ? undefined : money(row['gmv_30d_minor'], row['currency']),
      holdBalance:
        row['held_minor'] === null ? undefined : money(row['held_minor'], row['currency']),
      openDisputes: Number(row['open_disputes'] ?? 0),
      openSos: Number(row['open_sos'] ?? 0),
    }));
  }
}
