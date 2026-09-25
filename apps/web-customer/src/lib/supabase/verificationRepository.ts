// VerificationRepository (customer facial verification) over Supabase,
// mirroring packages/suskii_data/lib/src/supabase/supabase_verification_repository.dart.
//
// Supported: biometric consent via `record_consent`, session start via
// `start_verification_session`, state via `get_my_kyc_profile` (the
// `customer_facial` row). Blocked (CR-20260923-08/09/10): `submitIdLookup`
// needs client-side ID-number encryption the contract has no key story for,
// and there is no RPC to submit the liveness result — the client must never
// decide the verification verdict, so it stays feature-unavailable rather
// than sending plaintext or self-declaring an outcome.
//
// Wire gaps mapped defensively: the profile row has no session id (the
// step kind wire value stands in) and no `updated_at` (`expires_at` stands
// in, epoch when absent). Watching polls — KYC step state is RPC-only with
// no realtime topic.

import { AppError, ErrorCodes } from '@/mocks/errors';
import type { Unsubscribe } from '@/mocks/repos/base';
import type {
  KycStepStatus,
  LivenessResult,
  LivenessSession,
  VerificationSession,
} from '@/mocks/types';

import { SupabaseGateway, type Row } from './gateway';
import { verificationSessionFromProfileRow } from './mappers';

const CUSTOMER_FACIAL = 'customer_facial';
const POLL_INTERVAL_MS = 15_000;

export class SupabaseVerificationRepository {
  constructor(private readonly gateway: SupabaseGateway) {}

  async getCustomerVerification(): Promise<VerificationSession | undefined> {
    const rows = await this.profileRows();
    for (const row of rows) {
      if (row['kind'] === CUSTOMER_FACIAL) {
        return verificationSessionFromProfileRow(row);
      }
    }
    return undefined;
  }

  /** Emits the current session immediately, then re-polls every 15 s (KYC
   * step state is RPC-only, no realtime topic — same as the Dart impl's
   * Stream.periodic poll). A failed poll keeps the timer; the next tick
   * retries. */
  watchCustomerVerification(
    onChange: (session: VerificationSession | undefined) => void,
  ): Unsubscribe {
    let active = true;
    const load = async (): Promise<void> => {
      try {
        const session = await this.getCustomerVerification();
        if (active) onChange(session);
      } catch {
        // Keep polling; the next tick retries the fetch.
      }
    };
    void load();
    const timer = setInterval(() => void load(), POLL_INTERVAL_MS);
    return () => {
      active = false;
      clearInterval(timer);
    };
  }

  /** Records explicit consent for biometric processing. */
  async giveBiometricConsent(idempotencyKey: string): Promise<VerificationSession> {
    await this.gateway.rpc('record_consent', {
      p_idempotency_key: idempotencyKey,
      p_kind: 'biometric',
      p_granted: true,
    });
    return (await this.getCustomerVerification()) ?? this.fallback('not_started');
  }

  /** Throws ERR_CONSENT_REQUIRED (raised by the RPC) when consent was not given. */
  async startFacialVerification(idempotencyKey: string): Promise<VerificationSession> {
    await this.gateway.rpc('start_verification_session', {
      p_idempotency_key: idempotencyKey,
      p_kind: CUSTOMER_FACIAL,
    });
    return (await this.getCustomerVerification()) ?? this.fallback('in_progress');
  }

  /** On-device liveness stand-in (Smile ID SDK plugs in later) — same role
   * as the mobile IdentityVerificationAdapter, which stays mock over Supabase
   * too. The outcome never reaches the server: the only submission path is
   * submitIdLookup, which is feature-unavailable below, so no client-decided
   * verdict is ever submitted (CR-20260923-09). */
  async startLivenessSession(): Promise<LivenessSession> {
    return {
      sessionId: `liveness-${Date.now()}`,
      expiresAt: new Date(Date.now() + 10 * 60_000),
    };
  }

  async captureLiveness(_sessionId: string): Promise<LivenessResult> {
    return { outcome: 'success' };
  }

  async submitIdLookup(
    _sessionId: string,
    _idType: string,
    _idNumber: string,
    _idempotencyKey: string,
  ): Promise<VerificationSession> {
    // submit_identity_document expects id-number ciphertext + blind index;
    // the client has no encryption story (CR-20260923-08) and no RPC
    // accepts the liveness result (CR-20260923-09). Sending plaintext or
    // a client-decided outcome would weaken the security model.
    throw new AppError(ErrorCodes.featureUnavailable);
  }

  private async profileRows(): Promise<Row[]> {
    const rows = await this.gateway.rpc('get_my_kyc_profile');
    return (Array.isArray(rows) ? rows : []) as Row[];
  }

  private fallback(status: KycStepStatus): VerificationSession {
    return {
      id: CUSTOMER_FACIAL,
      kind: 'customer_facial',
      status,
      updatedAt: new Date(),
    };
  }
}
