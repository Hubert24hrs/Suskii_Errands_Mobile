/// Stable error codes. Placeholder set until Claude Code publishes the official
/// error-code contract; the UI maps code → localization key, never raw text.
abstract final class ErrorCodes {
  static const String network = 'ERR_NETWORK';
  static const String unknown = 'ERR_UNKNOWN';
  static const String forceUpdateRequired = 'ERR_FORCE_UPDATE_REQUIRED';

  /// Wire value is `ERR_COUNTRY_NOT_SUPPORTED`: contracts 1.0.0-preview.1 replaced the app's
  /// own country-disabled name with the server's, which is the one that arrives.
  static const String countryDisabled = 'ERR_COUNTRY_NOT_SUPPORTED';
  static const String unauthenticated = 'ERR_UNAUTHENTICATED';
  static const String permissionDenied = 'ERR_PERMISSION_DENIED';
  static const String idempotencyKeyReused = 'ERR_IDEMPOTENCY_KEY_REUSED';

  // Mode / provider
  static const String providerNotVerified = 'ERR_PROVIDER_NOT_VERIFIED';
  static const String providerBusyAsCustomer = 'ERR_PROVIDER_BUSY_AS_CUSTOMER';
  static const String kycExpired = 'ERR_KYC_EXPIRED';
  static const String selfieCheckRequired = 'ERR_SELFIE_CHECK_REQUIRED';

  // Marketplace
  static const String requestNotFound = 'ERR_REQUEST_NOT_FOUND';
  static const String offerExpired = 'ERR_OFFER_EXPIRED';
  static const String offerRoundsExhausted = 'ERR_OFFER_ROUNDS_EXHAUSTED';
  static const String selfDealingBlocked = 'ERR_SELF_DEALING_BLOCKED';
  static const String jobNotCancellable = 'ERR_JOB_NOT_CANCELLABLE';

  /// Wire value is `ERR_ILLEGAL_TRANSITION`: the server raises that for every
  /// "not in a state where this is allowed" case, and two names for one rule is drift.
  static const String invalidState = 'ERR_ILLEGAL_TRANSITION';
  static const String callInProgress = 'ERR_CALL_IN_PROGRESS';

  /// Completion was attempted without the required proof-of-execution
  /// (category proof requirements unmet, or the delivery PIN not yet
  /// verified for a job with a destination).
  static const String proofRequired = 'ERR_PROOF_REQUIRED';

  /// Handover-PIN attempt limit reached. Terminal for that PIN: stop asking
  /// and route to support (verify_pin returns wrong-PIN results WITHOUT
  /// raising precisely so this limit cannot be rolled back).
  static const String pinAttemptsExceeded = 'ERR_PIN_ATTEMPTS_EXCEEDED';

  // Money
  static const String paymentFailed = 'ERR_PAYMENT_FAILED';
  static const String paymentTtlExpired = 'ERR_PAYMENT_TTL_EXPIRED';
  static const String insufficientBalance = 'ERR_INSUFFICIENT_BALANCE';
  static const String withdrawalBelowMinimum = 'ERR_WITHDRAWAL_BELOW_MINIMUM';
  static const String payoutAccountNotFound = 'ERR_PAYOUT_ACCOUNT_NOT_FOUND';

  // Verification
  static const String otpInvalid = 'ERR_OTP_INVALID';
  static const String otpRateLimited = 'ERR_OTP_RATE_LIMITED';
  static const String verificationFailed = 'ERR_VERIFICATION_FAILED';
  static const String verificationRequired = 'ERR_VERIFICATION_REQUIRED';
  static const String consentRequired = 'ERR_CONSENT_REQUIRED';
  static const String verificationRejected = 'ERR_VERIFICATION_REJECTED';
  static const String kycStepInvalid = 'ERR_KYC_STEP_INVALID';
  static const String kycIncomplete = 'ERR_KYC_INCOMPLETE';

  // Features
  static const String featureUnavailable = 'ERR_FEATURE_UNAVAILABLE';
  static const String unsupportedLanguage = 'ERR_UNSUPPORTED_LANGUAGE';
  static const String promoInvalid = 'ERR_PROMO_INVALID';
}

/// Error type surfaced to the app. [messageKey] is a localization key.
class AppError implements Exception {
  const AppError(this.code, {this.messageKey, this.details});

  final String code;
  final String? messageKey;
  final Object? details;

  @override
  String toString() => 'AppError($code)';
}
