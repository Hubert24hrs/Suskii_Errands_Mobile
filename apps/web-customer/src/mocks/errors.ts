// Stable error codes mirroring packages/suskii_core/lib/src/errors.dart,
// plus the marketplace/chat codes from the offer-negotiation and payment
// state machines (docs/plan/state-machines). The UI maps code →
// localization key, never raw text.

export const ErrorCodes = {
  network: 'ERR_NETWORK',
  unknown: 'ERR_UNKNOWN',
  internal: 'ERR_INTERNAL',
  forceUpdateRequired: 'ERR_FORCE_UPDATE_REQUIRED',
  countryDisabled: 'ERR_COUNTRY_DISABLED',
  countryNotSupported: 'ERR_COUNTRY_NOT_SUPPORTED',
  unauthenticated: 'ERR_UNAUTHENTICATED',
  permissionDenied: 'ERR_PERMISSION_DENIED',
  idempotencyKeyReused: 'ERR_IDEMPOTENCY_KEY_REUSED',

  // Mode / provider
  providerNotVerified: 'ERR_PROVIDER_NOT_VERIFIED',
  providerBusyAsCustomer: 'ERR_PROVIDER_BUSY_AS_CUSTOMER',
  kycExpired: 'ERR_KYC_EXPIRED',
  selfieCheckRequired: 'ERR_SELFIE_CHECK_REQUIRED',

  // Marketplace
  offerExpired: 'ERR_OFFER_EXPIRED',
  offerNotActive: 'ERR_OFFER_NOT_ACTIVE',
  offerNotYourTurn: 'ERR_OFFER_NOT_YOUR_TURN',
  offerAlreadyPending: 'ERR_OFFER_ALREADY_PENDING',
  offerRoundsExhausted: 'ERR_OFFER_ROUNDS_EXHAUSTED',
  priceOutOfRange: 'ERR_PRICE_OUT_OF_RANGE',
  selfDealingBlocked: 'ERR_SELF_DEALING_BLOCKED',
  jobNotCancellable: 'ERR_JOB_NOT_CANCELLABLE',
  invalidState: 'ERR_INVALID_STATE',
  callInProgress: 'ERR_CALL_IN_PROGRESS',
  chatClosed: 'ERR_CHAT_CLOSED',

  // Money
  paymentFailed: 'ERR_PAYMENT_FAILED',
  paymentTtlExpired: 'ERR_PAYMENT_TTL_EXPIRED',
  insufficientBalance: 'ERR_INSUFFICIENT_BALANCE',
  withdrawalBelowMinimum: 'ERR_WITHDRAWAL_BELOW_MINIMUM',
  payoutAccountNotFound: 'ERR_PAYOUT_ACCOUNT_NOT_FOUND',

  // Verification
  otpInvalid: 'ERR_OTP_INVALID',
  otpRateLimited: 'ERR_OTP_RATE_LIMITED',
  verificationFailed: 'ERR_VERIFICATION_FAILED',
  verificationRequired: 'ERR_VERIFICATION_REQUIRED',
  consentRequired: 'ERR_CONSENT_REQUIRED',
  verificationRejected: 'ERR_VERIFICATION_REJECTED',
  kycStepInvalid: 'ERR_KYC_STEP_INVALID',
  kycIncomplete: 'ERR_KYC_INCOMPLETE',

  // Features
  featureUnavailable: 'ERR_FEATURE_UNAVAILABLE',
  unsupportedLanguage: 'ERR_UNSUPPORTED_LANGUAGE',
  promoInvalid: 'ERR_PROMO_INVALID',
} as const;

export type ErrorCode = (typeof ErrorCodes)[keyof typeof ErrorCodes];

/** Error type surfaced to the app. `messageKey` is a localization key. */
export class AppError extends Error {
  readonly code: ErrorCode;
  readonly messageKey?: string;
  readonly details?: unknown;

  constructor(code: ErrorCode, options?: { messageKey?: string; details?: unknown }) {
    super(code);
    this.name = 'AppError';
    this.code = code;
    this.messageKey = options?.messageKey;
    this.details = options?.details;
  }

  override toString(): string {
    return `AppError(${this.code})`;
  }
}

export function isAppError(error: unknown, code?: ErrorCode): error is AppError {
  return (
    error instanceof AppError && (code === undefined || error.code === code)
  );
}
