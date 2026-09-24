// Bootstrap, auth/persona, user and catalog repositories (customer scope).

import { syncServerClock } from '../../lib/serverClock';
import { Emitter } from '../behavior';
import { AppError, ErrorCodes } from '../errors';
import { kMockVoiceLanguages, type MockDatabase } from '../fixtures';
import type { MockBehavior } from '../behavior';
import {
  jobNeedsAttention,
  type AppBootstrap,
  type AppNotification,
  type AppUser,
  type AuthState,
  type CountryPack,
  type PriceBand,
  type PriceBandBasis,
  type PriceBandConfidence,
  type ServiceCategory,
  type Urgency,
  type UserMode,
} from '../types';
import { MockRepo, type Unsubscribe } from './base';

export class MockBootstrapRepository extends MockRepo {
  constructor(db: MockDatabase, behavior: MockBehavior) {
    super(db, behavior);
  }

  async getBootstrap(): Promise<AppBootstrap> {
    await this.gate();
    const user = this.db.users[this.behavior.currentUserId];
    const pack =
      this.db.countryPacks[user?.countryCode ?? 'NG'] ?? this.db.countryPacks['NG'];
    if (pack.status === 'disabled') {
      throw new AppError(ErrorCodes.countryNotSupported);
    }
    // The simulated server clock: device time plus the configured skew.
    syncServerClock(new Date(Date.now() + this.behavior.serverClockSkewMs));
    const activeJob = Object.values(this.db.requests).find(
      (r) =>
        (r.customerId === user?.id || r.providerId === user?.id) &&
        jobNeedsAttention(r.status),
    );
    return {
      user,
      countryPack: pack,
      featureFlags: {
        aiConcierge: true,
        voiceConcierge: true,
        inAppCalls: true,
        referrals: true,
        scheduledErrands: true,
      },
      voiceLanguages: { ...kMockVoiceLanguages },
      minSupportedAppVersion: '0.1.0',
      serverTime: this.now(),
      unreadNotifications: this.db.notifications.filter((n) => !n.read).length,
      activeJobBanner:
        activeJob == null
          ? undefined
          : {
              jobId: activeJob.id,
              status: activeJob.status,
              otherPartyName: activeJob.providerId
                ? (this.db.providers[activeJob.providerId]?.displayName ??
                  'Provider')
                : 'Suskii',
              categoryLabelKey: (
                this.db.categories.find((c) => c.id === activeJob.categoryId) ??
                this.db.categories[this.db.categories.length - 1]
              ).labelKey,
              agreedPrice: activeJob.agreedPrice,
            },
    };
  }

  watchNotifications(onChange: (notification: AppNotification) => void): Unsubscribe {
    return this.db.notificationEvents.subscribe(onChange);
  }
}

export class MockAuthRepository extends MockRepo {
  private readonly stateEvents = new Emitter<AuthState>();
  private state: AuthState = { status: 'signed_out' };

  /** Emits the current state immediately, then every change. */
  authStateChanges(onChange: (state: AuthState) => void): Unsubscribe {
    onChange(this.state);
    return this.stateEvents.subscribe(onChange);
  }

  private setState(state: AuthState): void {
    this.state = state;
    this.stateEvents.emit(state);
  }

  async requestPhoneOtp(phoneE164: string): Promise<void> {
    await this.gate();
  }

  async verifyPhoneOtp(phoneE164: string, code: string): Promise<AppUser> {
    await this.gate();
    if (!/^\d{6}$/.test(code)) throw new AppError(ErrorCodes.otpInvalid);
    const user = this.currentUser;
    this.setState({ status: 'signed_in', user });
    return user;
  }

  async requestEmailOtp(email: string): Promise<void> {
    await this.gate();
  }

  async verifyEmailOtp(email: string, code: string): Promise<AppUser> {
    await this.gate();
    if (!/^\d{6}$/.test(code)) throw new AppError(ErrorCodes.otpInvalid);
    const user = this.currentUser;
    const updated: AppUser = { ...user, email: user.email ?? email };
    this.db.users[user.id] = updated;
    this.setState({ status: 'signed_in', user: updated });
    return updated;
  }

  async signInWithGoogle(): Promise<AppUser> {
    await this.gate();
    throw new AppError(ErrorCodes.featureUnavailable);
  }

  async signInWithApple(): Promise<AppUser> {
    await this.gate();
    throw new AppError(ErrorCodes.featureUnavailable);
  }

  async signOut(): Promise<void> {
    await this.gate();
    this.setState({ status: 'signed_out' });
  }

  /**
   * Mock-only demo hook: switch the signed-in persona (`user-ada` verified,
   * `user-chidi` unverified). No real backend equivalent.
   */
  switchPersona(userId: string): AppUser {
    const user = this.db.users[userId];
    if (!user) throw new AppError(ErrorCodes.unknown);
    this.behavior.currentUserId = userId;
    this.setState({ status: 'signed_in', user });
    return user;
  }
}

export class MockUserRepository extends MockRepo {
  private readonly profileEvents = new Emitter<AppUser>();

  async getProfile(): Promise<AppUser> {
    await this.gate();
    return this.currentUser;
  }

  watchProfile(onChange: (user: AppUser) => void): Unsubscribe {
    onChange(this.currentUser);
    return this.profileEvents.subscribe(onChange);
  }

  /** Throws ERR_PROVIDER_NOT_VERIFIED when switching without provider KYC. */
  async setActiveMode(mode: UserMode, idempotencyKey: string): Promise<UserMode> {
    await this.gate();
    return this.idempotent('setActiveMode', idempotencyKey, mode, () => {
      const user = this.currentUser;
      if (mode === 'provider' && user.providerVerification !== 'verified') {
        throw new AppError(ErrorCodes.providerNotVerified);
      }
      const updated: AppUser = { ...user, activeMode: mode };
      this.db.users[user.id] = updated;
      this.profileEvents.emit(updated);
      return mode;
    });
  }
}

/** Simulated price-intelligence bands (minor units, NGN scale). */
const PRICE_BANDS: Record<
  string,
  [number, number, number, number, PriceBandConfidence]
> = {
  errands_delivery: [150000, 300000, 500000, 214, 'high'],
  shopping: [250000, 500000, 900000, 187, 'high'],
  cleaning_laundry: [1500000, 2500000, 4000000, 96, 'medium'],
  moving: [4000000, 7500000, 12000000, 61, 'medium'],
  food_pickup: [100000, 200000, 350000, 243, 'high'],
  document_delivery: [200000, 400000, 650000, 74, 'medium'],
};

export class MockCatalogRepository extends MockRepo {
  async getCategories(): Promise<ServiceCategory[]> {
    await this.gate();
    return [...this.db.categories];
  }

  async getCountryPack(countryCode: string): Promise<CountryPack> {
    await this.gate();
    const pack = this.db.countryPacks[countryCode.toUpperCase()];
    if (!pack) throw new AppError(ErrorCodes.countryNotSupported);
    return pack;
  }

  /**
   * Server-computed P25/P50/P75 band for a category — advisory only, never
   * used to set prices (ai-design §9). Nullable per the contract: no row
   * means no basis for a hint. The mock always has a band.
   */
  async getPriceBand(options: {
    categoryId: string;
    urgency?: Urgency;
    cityId?: string;
  }): Promise<PriceBand | null> {
    await this.gate();
    const currency =
      this.db.countryPacks[this.currentUser.countryCode]?.currencyCode ?? 'NGN';
    const band = PRICE_BANDS[options.categoryId];
    const [p25, p50, p75, sampleSize, confidence] = band ?? [
      200000, 450000, 800000, 12, 'low' as PriceBandConfidence,
    ];
    const basis: PriceBandBasis = band ? 'history' : 'rules';
    return {
      p25: { amountMinor: p25, currency },
      p50: { amountMinor: p50, currency },
      p75: { amountMinor: p75, currency },
      sampleSize,
      confidence,
      basis,
    };
  }
}
