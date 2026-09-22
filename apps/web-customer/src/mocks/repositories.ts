// Mock repositories for the web customer app (M7), mirroring the Dart mock
// layer in packages/suskii_data. The client displays and requests — the
// server decides. Every mutating function takes an idempotencyKey (use
// newIdempotencyKey() from @/lib/idempotency). Watch methods take a callback
// and return an unsubscribe function.
//
// At M9 these are replaced by Supabase-backed implementations behind the
// same signatures.

import { mockBehavior } from './behavior';
import { db } from './fixtures';
import { MockBootstrapRepository, MockAuthRepository, MockUserRepository, MockCatalogRepository } from './repos/core';
import { MockRequestRepository, MockOfferRepository } from './repos/requests';
import {
  MockPaymentRepository,
  MockTrackingRepository,
  MockChatRepository,
  MockRatingRepository,
  MockSafetyRepository,
  MockJobProgressRepository,
} from './repos/jobs';
import {
  MockWalletRepository,
  MockReferralRepository,
  MockPromoRepository,
  MockDisputeRepository,
  MockSupportRepository,
  MockSettingsRepository,
} from './repos/account';
import { MockConciergeRepository, MockVerificationRepository } from './repos/concierge';

export { mockBehavior } from './behavior';
export { db, createMockDatabase, MockDatabase } from './fixtures';
export { AppError, ErrorCodes, isAppError } from './errors';
export type { ErrorCode } from './errors';
export type { Unsubscribe } from './repos/base';

export {
  MockBootstrapRepository,
  MockAuthRepository,
  MockUserRepository,
  MockCatalogRepository,
  MockRequestRepository,
  MockOfferRepository,
  MockPaymentRepository,
  MockTrackingRepository,
  MockChatRepository,
  MockRatingRepository,
  MockSafetyRepository,
  MockJobProgressRepository,
  MockWalletRepository,
  MockReferralRepository,
  MockPromoRepository,
  MockDisputeRepository,
  MockSupportRepository,
  MockSettingsRepository,
  MockConciergeRepository,
  MockVerificationRepository,
};

// Singletons over the shared seeded database. Construct your own instances
// with createMockDatabase() for isolated tests or demo resets.
export const bootstrapRepository = new MockBootstrapRepository(db, mockBehavior);
export const authRepository = new MockAuthRepository(db, mockBehavior);
export const userRepository = new MockUserRepository(db, mockBehavior);
export const catalogRepository = new MockCatalogRepository(db, mockBehavior);
export const requestRepository = new MockRequestRepository(db, mockBehavior);
export const offerRepository = new MockOfferRepository(db, mockBehavior);
export const paymentRepository = new MockPaymentRepository(db, mockBehavior);
export const trackingRepository = new MockTrackingRepository(db, mockBehavior);
export const chatRepository = new MockChatRepository(db, mockBehavior);
export const ratingRepository = new MockRatingRepository(db, mockBehavior);
export const safetyRepository = new MockSafetyRepository(db, mockBehavior);
export const jobProgressRepository = new MockJobProgressRepository(db, mockBehavior);
export const walletRepository = new MockWalletRepository(db, mockBehavior);
export const referralRepository = new MockReferralRepository(db, mockBehavior);
export const promoRepository = new MockPromoRepository(db, mockBehavior);
export const disputeRepository = new MockDisputeRepository(db, mockBehavior);
export const supportRepository = new MockSupportRepository(db, mockBehavior);
export const settingsRepository = new MockSettingsRepository(db, mockBehavior);
export const conciergeRepository = new MockConciergeRepository(db, mockBehavior);
export const verificationRepository = new MockVerificationRepository(db, mockBehavior);
