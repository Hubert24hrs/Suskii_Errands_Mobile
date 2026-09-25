// Customer-scope entity and enum types mirroring packages/suskii_domain.
// Enum wire values are lower snake_case, matching the Dart @JsonValue
// annotations and the Postgres/Supabase contracts. Dates are `Date`
// (the Dart side uses DateTime). Money is integer minor units + ISO 4217.

import type { MoneyLike } from '../lib/money';

export type Money = MoneyLike;

export interface GeoPoint {
  latitude: number;
  longitude: number;
}

// ---------------------------------------------------------------------------
// Enums (wire values)
// ---------------------------------------------------------------------------

export type UserMode = 'customer' | 'provider';

export type CountryStatus = 'disabled' | 'beta' | 'live';

export type Urgency = 'flexible' | 'standard' | 'urgent' | 'emergency';

export type TrustLevel = 'new' | 'verified' | 'trusted' | 'elite';

export type VehicleType =
  | 'walking'
  | 'bicycle'
  | 'motorcycle'
  | 'tricycle'
  | 'car'
  | 'van'
  | 'truck';

export type VerificationStatus =
  | 'unverified'
  | 'pending'
  | 'in_review'
  | 'verified'
  | 'rejected'
  | 'suspended'
  | 'expired';

/** The 20 job lifecycle states from the master spec, in canonical order. */
export type JobStatus =
  | 'draft'
  | 'published'
  | 'offers_received'
  | 'negotiating'
  | 'agreed'
  | 'payment_pending'
  | 'paid_held'
  | 'assigned'
  | 'en_route'
  | 'arrived'
  | 'in_progress'
  | 'completed_by_provider'
  | 'confirmed'
  | 'settlement_pending'
  | 'settled'
  | 'closed'
  | 'cancelled'
  | 'expired'
  | 'disputed'
  | 'refunded';

export const TERMINAL_JOB_STATUSES: ReadonlySet<JobStatus> = new Set([
  'closed',
  'cancelled',
  'expired',
  'refunded',
]);

/** States where the job banner must stay visible across both app modes. */
export const ATTENTION_JOB_STATUSES: ReadonlySet<JobStatus> = new Set([
  'agreed',
  'payment_pending',
  'paid_held',
  'assigned',
  'en_route',
  'arrived',
  'in_progress',
  'completed_by_provider',
  'disputed',
]);

export function isTerminalJobStatus(status: JobStatus): boolean {
  return TERMINAL_JOB_STATUSES.has(status);
}

export function jobNeedsAttention(status: JobStatus): boolean {
  return ATTENTION_JOB_STATUSES.has(status);
}

export type OfferStatus =
  | 'pending'
  | 'countered'
  | 'accepted'
  | 'declined'
  | 'expired'
  | 'withdrawn';

export type PaymentStatus =
  | 'unpaid'
  | 'pending'
  | 'held'
  | 'failed'
  | 'refunded'
  | 'partially_refunded';

/** Customer-facing payment rails; per-country availability from the pack. */
export type PaymentMethod = 'card' | 'bank_transfer' | 'mobile_money' | 'ussd';

export type SosStatus = 'active' | 'resolved';

export type DisputeStatus = 'open' | 'in_review' | 'resolved' | 'rejected';

export type SupportTicketStatus =
  | 'open'
  | 'awaiting_user'
  | 'resolved'
  | 'closed';

export type ReferralCommissionStatus =
  | 'pending'
  | 'earned'
  | 'holding'
  | 'available'
  | 'reversed';

export type ChatMessageType =
  | 'text'
  | 'image'
  | 'voice_note'
  | 'location'
  | 'offer_card'
  | 'system';

export type WalletTransactionKind =
  | 'credit'
  | 'debit'
  | 'hold'
  | 'release'
  | 'refund'
  | 'payout'
  | 'referral'
  | 'tip'
  | 'item_float';

export type WalletTransactionStatus =
  | 'pending'
  | 'awaiting_approval'
  | 'completed'
  | 'failed'
  | 'reversed';

export type ProviderKind = 'individual' | 'business';

export type KycStepKind =
  | 'customer_facial'
  | 'government_id'
  | 'provider_facial'
  | 'id_document_capture'
  | 'police_clearance'
  | 'address'
  | 'guarantor'
  | 'payout_account'
  | 'vehicle_documents'
  | 'credentials';

export type KycStepStatus =
  | 'not_started'
  | 'consent_pending'
  | 'in_progress'
  | 'in_review'
  | 'verified'
  | 'rejected'
  | 'expired';

/** Server-style outcome of an identity-verification vendor call. */
export type IdentityCheckOutcome = 'success' | 'retry' | 'failed';

export type PriceBandConfidence = 'low' | 'medium' | 'high';

/** `rules` = rough guide until enough completed jobs exist for `history`. */
export type PriceBandBasis = 'rules' | 'history';

export type ConciergeRole = 'user' | 'assistant' | 'system';

/**
 * What the concierge assistant proposes the UI do next. The concierge holds
 * no publish/accept/pay capability — these are render hints only.
 */
export type ConciergeProposedAction =
  | 'none'
  | 'show_publish_card'
  | 'show_offer_comparison'
  | 'show_sos_card'
  | 'handoff_to_form';

// ---------------------------------------------------------------------------
// User / provider
// ---------------------------------------------------------------------------

export interface AppUser {
  id: string;
  displayName: string;
  countryCode: string;
  preferredLanguage: string;
  activeMode: UserMode;
  customerVerification: VerificationStatus;
  providerVerification: VerificationStatus;
  trustLevel: TrustLevel;
  createdAt: Date;
  phoneE164?: string;
  email?: string;
  photoUrl?: string;
  referralCode?: string;
}

export interface ProviderProfile {
  userId: string;
  kind: ProviderKind;
  serviceCategoryIds: string[];
  serviceAreaIds: string[];
  rating: number;
  completedJobs: number;
  cancellationRate: number;
  avgResponseTimeSeconds: number;
  online: boolean;
  verificationStatus: VerificationStatus;
  displayName?: string;
  photoUrl?: string;
  businessName?: string;
  organizationId?: string;
  vehicleType?: VehicleType;
}

export type AuthStatus = 'unknown' | 'signed_out' | 'signed_in';

export interface AuthState {
  status: AuthStatus;
  user?: AppUser;
}

// ---------------------------------------------------------------------------
// Requests / offers
// ---------------------------------------------------------------------------

/** Pickup/destination: free-text landmark label plus optional coordinates. */
export interface PlaceRef {
  label: string;
  point?: GeoPoint;
  landmarkNote?: string;
}

export interface JobRequest {
  id: string;
  customerId: string;
  categoryId: string;
  isCustomCategory: boolean;
  description: string;
  mediaPaths: string[];
  pickup: PlaceRef;
  urgency: Urgency;
  status: JobStatus;
  createdAt: Date;
  destination?: PlaceRef;
  scheduledAt?: Date;
  preferredPrice?: Money;
  itemFloat?: Money;
  declaredValue?: Money;
  agreedPrice?: Money;
  /** Server-computed money breakdown for the agreed price. Null until agreed. */
  agreedBreakdown?: PriceBreakdown;
  providerId?: string;
  expiresAt?: Date;
}

/** Which handover PIN — jobs with a destination have both. PINs are never
 * stored on the entity; they come from `reveal_job_pin` on demand. */
export type HandoverPinKind = 'pickup' | 'delivery';

export interface CreateRequestInput {
  categoryId: string;
  description: string;
  pickup: PlaceRef;
  destination?: PlaceRef;
  isCustomCategory?: boolean;
  /** The customer's own label for a custom category — sent separately
   * (`p_custom_category_label`), never baked into the description. */
  customCategoryLabel?: string;
  mediaPaths?: string[];
  urgency?: Urgency;
  scheduledAt?: Date;
  preferredPrice?: Money;
  itemFloat?: Money;
  declaredValue?: Money;
}

/** Editable fields while a request is still a draft. */
export interface UpdateRequestInput {
  categoryId?: string;
  isCustomCategory?: boolean;
  description?: string;
  mediaPaths?: string[];
  pickup?: PlaceRef;
  destination?: PlaceRef;
  urgency?: Urgency;
  scheduledAt?: Date;
  preferredPrice?: Money;
  itemFloat?: Money;
  declaredValue?: Money;
}

export interface Offer {
  id: string;
  requestId: string;
  providerId: string;
  providerName: string;
  providerRating: number;
  providerTrustLevel: TrustLevel;
  amount: Money;
  status: OfferStatus;
  /** Negotiation round (1-based). Server enforces max rounds per category. */
  round: number;
  createdAt: Date;
  message?: string;
  /** Distance in meters at offer time (server-computed). */
  distanceMeters?: number;
  /** Estimated minutes for the provider to reach pickup (server-computed). */
  etaMinutes?: number;
  /** Server-computed estimated payout shown to the provider. */
  payoutEstimate?: PriceBreakdown;
  expiresAt?: Date;
}

/**
 * Authoritative money breakdown. ALWAYS server-computed — the UI renders
 * these values and never derives them.
 */
export interface PriceBreakdown {
  gross: Money;
  platformCommission: Money;
  net: Money;
  providerPayout: Money;
  /** Commission rate snapshot in basis points (1250 = 12.5%). */
  commissionRateBps: number;
  estimatedGatewayFee?: Money;
  actualGatewayFee?: Money;
  tip?: Money;
  referralCommissionTotal?: Money;
}

// ---------------------------------------------------------------------------
// Payments
// ---------------------------------------------------------------------------

/**
 * A payment for one job. Server-initialized only — the client never marks a
 * payment successful; status flips when the gateway webhook + server-side
 * verify confirm it.
 */
export interface Payment {
  id: string;
  jobId: string;
  amount: Money;
  method: PaymentMethod;
  status: PaymentStatus;
  createdAt: Date;
  gatewayReference?: string;
  paidAt?: Date;
  /** Payment TTL window. Server timestamp — render against the clock offset. */
  expiresAt?: Date;
  /** Localizable reason key when status is failed. */
  failureReasonKey?: string;
}

export interface PaymentSession {
  payment: Payment;
  /** Gateway checkout page for card/mobile-money (from get_payment_checkout —
   * the payments table's column grants exclude it). */
  checkoutUrl?: string;
  /** USSD code to dial (method = ussd). */
  ussdCode?: string;
  /** Reference to quote on a bank transfer (method = bank_transfer). */
  reference?: string;
}

// ---------------------------------------------------------------------------
// Wallet / referrals / promos
// ---------------------------------------------------------------------------

/** Balances are derived server-side from the double-entry ledger. */
export interface WalletSummary {
  available: Money;
  pending: Money;
  lifetimeEarned?: Money;
}

export interface WalletTransaction {
  id: string;
  kind: WalletTransactionKind;
  status: WalletTransactionStatus;
  amount: Money;
  createdAt: Date;
  referenceId?: string;
  /** Localization key for the human-readable description. */
  descriptionKey?: string;
}

export interface ReferralSummary {
  code: string;
  shareLink: string;
  invitedCount: number;
  activeReferrals: number;
  earnedTotal: Money;
  holding: Money;
  available: Money;
}

/**
 * Promo/coupon campaign. All discount math is server-side; the client renders
 * the server-computed percent/cap.
 */
export interface Promo {
  code: string;
  titleKey: string;
  descriptionKey: string;
  percentOff: number;
  expiresAt: Date;
  maxDiscount?: Money;
  redeemed: boolean;
}

// ---------------------------------------------------------------------------
// Disputes / support
// ---------------------------------------------------------------------------

export interface Dispute {
  id: string;
  jobId: string;
  openedBy: string;
  /** Localization key, never free text for the category itself. */
  reasonKey: string;
  status: DisputeStatus;
  createdAt: Date;
  details?: string;
  evidencePaths?: string[];
  /** Response SLA (server timestamp). */
  slaDeadline?: Date;
  /** Localizable resolution summary key, set when resolved. */
  resolutionNoteKey?: string;
  /** Refund decided by the server (partial or full). Null = no refund. */
  refundAmount?: Money;
}

export interface SupportMessage {
  id: string;
  body: string;
  fromUser: boolean;
  createdAt: Date;
  /** AI first-line triage replies are labelled honestly in the UI. */
  aiTriage: boolean;
}

export interface SupportTicket {
  id: string;
  subject: string;
  status: SupportTicketStatus;
  createdAt: Date;
  messages: SupportMessage[];
}

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------

export interface NotificationPreferences {
  push: boolean;
  sms: boolean;
  email: boolean;
  /** Marketing messages only; transactional alerts always go through. */
  marketing: boolean;
  /** Quiet hours as minutes since midnight, local time. Undefined = off. */
  quietStartMinutes?: number;
  quietEndMinutes?: number;
}

/** A trusted contact (up to 5 per user) — notified on SOS. */
export interface TrustedContact {
  id: string;
  name: string;
  phoneE164: string;
}

// ---------------------------------------------------------------------------
// Chat / tracking / safety / ratings
// ---------------------------------------------------------------------------

export interface ChatMessage {
  id: string;
  jobId: string;
  senderId: string;
  type: ChatMessageType;
  createdAt: Date;
  text?: string;
  mediaPath?: string;
  offerId?: string;
  location?: GeoPoint;
  readAt?: Date;
}

export interface SosAlert {
  id: string;
  jobId: string;
  triggeredBy: string;
  status: SosStatus;
  createdAt: Date;
  location?: GeoPoint;
  /** How many trusted contacts the server notified. */
  trustedContactsNotified: number;
}

/** Shareable, expiring live-tracking link for trusted contacts. */
export interface TripShare {
  url: string;
  /** Server timestamp — render countdowns against the clock offset. */
  expiresAt: Date;
}

/** One rating per party per job; aggregates are server-computed. */
export interface Rating {
  id: string;
  jobId: string;
  raterId: string;
  rateeId: string;
  /** 1–5. */
  stars: number;
  /** Localization keys of the selected quick tags. */
  tagKeys: string[];
  comment?: string;
  createdAt: Date;
}

// ---------------------------------------------------------------------------
// Catalog / bootstrap
// ---------------------------------------------------------------------------

export interface ServiceCategory {
  id: string;
  /** Localization key, not display text. */
  labelKey: string;
  iconKey: string;
  allowsCustom: boolean;
  /** Offer TTL for this category (spec default: 600 = 10 minutes). */
  offerTtlSeconds: number;
  /** Max counter rounds per negotiation thread (spec default: 5). */
  maxCounterRounds: number;
  /** Server-owned proof counts per kind (service_categories.proof_requirements). */
  proofRequirements?: Record<string, number>;
}

/**
 * Server-computed P25/P50/P75 price band. Advisory only — the spec forbids
 * AI setting prices. `basis` tells the UI whether to label it a rough guide.
 */
export interface PriceBand {
  p25: Money;
  p50: Money;
  p75: Money;
  sampleSize: number;
  confidence: PriceBandConfidence;
  basis: PriceBandBasis;
}

export interface EmergencyNumber {
  labelKey: string;
  number: string;
}

/** Client-safe subset of a country pack. All country behaviour is data. */
export interface CountryPack {
  countryCode: string;
  status: CountryStatus;
  currencyCode: string;
  supportedLanguages: string[];
  defaultLanguage: string;
  launchCities: string[];
  emergencyNumbers: EmergencyNumber[];
  offerTtlSeconds: number;
  maxNegotiationRounds: number;
  minWithdrawal?: Money;
}

/** Compact summary of an in-flight job, shown as a banner. */
export interface ActiveJobBanner {
  jobId: string;
  status: JobStatus;
  otherPartyName: string;
  categoryLabelKey: string;
  agreedPrice?: Money;
}

/** Everything the app shell needs on cold start. */
export interface AppBootstrap {
  countryPack: CountryPack;
  featureFlags: Record<string, boolean>;
  /**
   * Per-language voice-concierge availability (OD-17). Absent/false means
   * voice is not offered for that language.
   */
  voiceLanguages: Record<string, boolean>;
  minSupportedAppVersion: string;
  unreadNotifications: number;
  /** Server clock at response time — feed to syncServerClock(). */
  serverTime: Date;
  user?: AppUser;
  activeJobBanner?: ActiveJobBanner;
}

export interface AppNotification {
  id: string;
  kind: string;
  title: string;
  body: string;
  read: boolean;
  createdAt: Date;
  deeplink?: string;
}

// ---------------------------------------------------------------------------
// Concierge
// ---------------------------------------------------------------------------

export interface ConciergeConversation {
  id: string;
  createdAt: Date;
  language?: string;
}

export interface ConciergeMessage {
  id: string;
  conversationId: string;
  role: ConciergeRole;
  text: string;
  createdAt: Date;
  /** The slot-filled request as the assistant currently understands it. */
  structuredDraft?: ConciergeDraft;
  proposedAction: ConciergeProposedAction;
}

/**
 * The request the concierge has structured so far. Money fields are NEVER
 * auto-filled by the concierge — the user sets the price on the publish
 * card / request form. The concierge holds no publish capability; the
 * publish card calls RequestRepository.publishRequest like any other draft.
 */
export interface ConciergeDraft {
  isCustomCategory: boolean;
  missingSlots: string[];
  /** The server-side draft JobRequest backing this structured draft. */
  requestId?: string;
  categoryId?: string;
  description?: string;
  pickup?: PlaceRef;
  destination?: PlaceRef;
  urgency?: Urgency;
  scheduledAt?: Date;
  preferredPrice?: Money;
  itemFloat?: Money;
  declaredValue?: Money;
}

// ---------------------------------------------------------------------------
// Customer verification
// ---------------------------------------------------------------------------

export interface VerificationSession {
  id: string;
  kind: KycStepKind;
  status: KycStepStatus;
  updatedAt: Date;
  rejectionReasonKey?: string;
  expiresAt?: Date;
}

export interface LivenessSession {
  sessionId: string;
  expiresAt: Date;
}

export interface LivenessResult {
  outcome: IdentityCheckOutcome;
  reasonKey?: string;
}
