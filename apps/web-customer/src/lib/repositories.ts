// Repository seam for the web customer app. Every screen imports
// repositories from here, never from '@/mocks/repositories' directly.
//
// The mock layer stays the default; a repository switches to its
// Supabase-backed implementation when the env config is present
// (NEXT_PUBLIC_SUPABASE_URL + NEXT_PUBLIC_SUPABASE_ANON_KEY). Slices wire
// one surface at a time — re-export order below mirrors
// packages/suskii_data/lib/suskii_data.dart's growth.

import {
  bootstrapRepository as mockBootstrapRepository,
  catalogRepository as mockCatalogRepository,
  chatRepository as mockChatRepository,
  conciergeRepository as mockConciergeRepository,
  disputeRepository as mockDisputeRepository,
  jobProgressRepository as mockJobProgressRepository,
  offerRepository as mockOfferRepository,
  paymentRepository as mockPaymentRepository,
  promoRepository as mockPromoRepository,
  ratingRepository as mockRatingRepository,
  referralRepository as mockReferralRepository,
  requestRepository as mockRequestRepository,
  safetyRepository as mockSafetyRepository,
  settingsRepository as mockSettingsRepository,
  supportRepository as mockSupportRepository,
  trackingRepository as mockTrackingRepository,
  verificationRepository as mockVerificationRepository,
  walletRepository as mockWalletRepository,
  authRepository as mockAuthRepository,
  userRepository as mockUserRepository,
} from '@/mocks/repositories';

import { SupabaseAuthRepository } from './supabase/authRepository';
import { SupabaseBootstrapRepository } from './supabase/bootstrapRepository';
import { SupabaseCatalogRepository } from './supabase/catalogRepository';
import { SupabaseChatRepository } from './supabase/chatRepository';
import { SupabaseDisputeRepository } from './supabase/disputeRepository';
import { SupabaseGateway } from './supabase/gateway';
import { SupabaseJobProgressRepository } from './supabase/jobProgressRepository';
import { SupabaseOfferRepository } from './supabase/offerRepository';
import { SupabasePaymentRepository } from './supabase/paymentRepository';
import { SupabaseRatingRepository } from './supabase/ratingRepository';
import { SupabaseReferralRepository } from './supabase/referralRepository';
import { SupabaseRequestRepository } from './supabase/requestRepository';
import { SupabaseSafetyRepository } from './supabase/safetyRepository';
import { SupabaseSettingsRepository } from './supabase/settingsRepository';
import { SupabaseSupportRepository } from './supabase/supportRepository';
import { SupabaseTrackingRepository } from './supabase/trackingRepository';
import { SupabaseUserRepository } from './supabase/userRepository';
import { SupabaseWalletRepository } from './supabase/walletRepository';

export { AppError, ErrorCodes, isAppError } from '@/mocks/errors';
export type { ErrorCode } from '@/mocks/errors';

/** Null unless the flavor provides Supabase env config. */
export const supabaseGateway = SupabaseGateway.fromEnv();

// Wired (W9.1): auth + user profile.
export const authRepository = supabaseGateway
  ? new SupabaseAuthRepository(supabaseGateway)
  : mockAuthRepository;
export const userRepository = supabaseGateway
  ? new SupabaseUserRepository(supabaseGateway)
  : mockUserRepository;

// Wired (W9.3): bootstrap + catalog.
export const bootstrapRepository = supabaseGateway
  ? new SupabaseBootstrapRepository(supabaseGateway)
  : mockBootstrapRepository;
export const catalogRepository = supabaseGateway
  ? new SupabaseCatalogRepository(supabaseGateway)
  : mockCatalogRepository;

// Wired (W9.4): requests + offers.
export const requestRepository = supabaseGateway
  ? new SupabaseRequestRepository(supabaseGateway)
  : mockRequestRepository;
export const offerRepository = supabaseGateway
  ? new SupabaseOfferRepository(supabaseGateway)
  : mockOfferRepository;

// Wired (W9.5): payments + job progress + ratings + safety.
export const paymentRepository = supabaseGateway
  ? new SupabasePaymentRepository(supabaseGateway)
  : mockPaymentRepository;
export const ratingRepository = supabaseGateway
  ? new SupabaseRatingRepository(supabaseGateway)
  : mockRatingRepository;
export const safetyRepository = supabaseGateway
  ? new SupabaseSafetyRepository(supabaseGateway)
  : mockSafetyRepository;
export const jobProgressRepository = supabaseGateway
  ? new SupabaseJobProgressRepository(supabaseGateway)
  : mockJobProgressRepository;

// Wired (W9.6): wallet + referrals + disputes. Promos stay on the mock
// (CR-20260923-04: no job-independent redemption on the wire).
export const walletRepository = supabaseGateway
  ? new SupabaseWalletRepository(supabaseGateway)
  : mockWalletRepository;
export const referralRepository = supabaseGateway
  ? new SupabaseReferralRepository(supabaseGateway)
  : mockReferralRepository;
export const disputeRepository = supabaseGateway
  ? new SupabaseDisputeRepository(supabaseGateway)
  : mockDisputeRepository;

// Wired (W9.7): chat + tracking.
export const chatRepository = supabaseGateway
  ? new SupabaseChatRepository(supabaseGateway)
  : mockChatRepository;
export const trackingRepository = supabaseGateway
  ? new SupabaseTrackingRepository(supabaseGateway)
  : mockTrackingRepository;

// Wired (W9.8): support + settings.
export const supportRepository = supabaseGateway
  ? new SupabaseSupportRepository(supabaseGateway)
  : mockSupportRepository;
export const settingsRepository = supabaseGateway
  ? new SupabaseSettingsRepository(supabaseGateway)
  : mockSettingsRepository;

// Mock-only until their wiring slices land.
export const promoRepository = mockPromoRepository;
export const conciergeRepository = mockConciergeRepository;
export const verificationRepository = mockVerificationRepository;
