// Repository seam for the web customer app. Every screen imports
// repositories from here, never from '@/lib/repositories' directly.
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
import { SupabaseGateway } from './supabase/gateway';
import { SupabaseOfferRepository } from './supabase/offerRepository';
import { SupabaseRequestRepository } from './supabase/requestRepository';
import { SupabaseUserRepository } from './supabase/userRepository';

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

// Mock-only until their wiring slices land.
export const paymentRepository = mockPaymentRepository;
export const trackingRepository = mockTrackingRepository;
export const chatRepository = mockChatRepository;
export const ratingRepository = mockRatingRepository;
export const safetyRepository = mockSafetyRepository;
export const jobProgressRepository = mockJobProgressRepository;
export const walletRepository = mockWalletRepository;
export const referralRepository = mockReferralRepository;
export const promoRepository = mockPromoRepository;
export const disputeRepository = mockDisputeRepository;
export const supportRepository = mockSupportRepository;
export const settingsRepository = mockSettingsRepository;
export const conciergeRepository = mockConciergeRepository;
export const verificationRepository = mockVerificationRepository;
