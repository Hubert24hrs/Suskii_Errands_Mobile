import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_l10n/suskii_l10n.dart';

/// Maps a stable error code to its localized message. Never show raw
/// exception text to users.
///
/// Every client-facing code in `contracts/v1/error-codes/codes.json` has a
/// message: the ones a person can act on have their own, and the rest fall
/// into a family (not found, invalid input, try again) rather than into
/// "Something went wrong" (audit 2026-09-27 Y.12).
String localizedError(AppLocalizations l10n, Object error) {
  if (error is! AppError) return l10n.errUnknown;
  final code = error.code;
  return _specific(l10n, code) ?? _family(l10n, code);
}

String? _specific(AppLocalizations l10n, String code) => switch (code) {
  ErrorCodes.network => l10n.errNetwork,
  ErrorCodes.forceUpdateRequired => l10n.errForceUpdateRequired,
  ErrorCodes.countryDisabled ||
  'ERR_COUNTRY_PACK_INCOMPLETE' => l10n.errCountryDisabled,
  ErrorCodes.unauthenticated ||
  'ERR_SESSION_NOT_FOUND' => l10n.errUnauthenticated,
  ErrorCodes.permissionDenied => l10n.errPermissionDenied,
  ErrorCodes.providerNotVerified => l10n.errProviderNotVerified,
  ErrorCodes.providerBusyAsCustomer => l10n.errProviderBusyAsCustomer,
  ErrorCodes.kycExpired => l10n.errKycExpired,
  ErrorCodes.selfieCheckRequired => l10n.errSelfieCheckRequired,
  ErrorCodes.requestNotFound => l10n.errRequestNotFound,
  ErrorCodes.offerExpired => l10n.errOfferExpired,
  ErrorCodes.offerRoundsExhausted => l10n.errOfferRoundsExhausted,
  ErrorCodes.selfDealingBlocked => l10n.errSelfDealingBlocked,
  ErrorCodes.jobNotCancellable => l10n.errJobNotCancellable,
  ErrorCodes.paymentFailed => l10n.errPaymentFailed,
  ErrorCodes.paymentTtlExpired => l10n.errPaymentTtlExpired,
  ErrorCodes.insufficientBalance => l10n.errInsufficientBalance,
  ErrorCodes.withdrawalBelowMinimum => l10n.errWithdrawalBelowMinimum,
  ErrorCodes.pinAttemptsExceeded => l10n.errPinAttemptsExceeded,
  ErrorCodes.otpInvalid => l10n.errOtpInvalid,
  ErrorCodes.otpRateLimited => l10n.errOtpRateLimited,
  ErrorCodes.verificationFailed => l10n.errVerificationFailed,
  ErrorCodes.featureUnavailable => l10n.errFeatureUnavailable,
  ErrorCodes.consentRequired => l10n.errConsentRequired,
  ErrorCodes.verificationRejected => l10n.errVerificationRejected,
  ErrorCodes.kycStepInvalid => l10n.errKycStepInvalid,
  ErrorCodes.kycIncomplete => l10n.errKycIncomplete,
  ErrorCodes.verificationRequired => l10n.errVerificationRequired,
  ErrorCodes.idempotencyKeyReused => l10n.errIdempotencyKeyReused,
  ErrorCodes.unsupportedLanguage ||
  'ERR_LANGUAGE_NOT_SUPPORTED' => l10n.errUnsupportedLanguage,
  ErrorCodes.invalidState => l10n.errInvalidState,
  ErrorCodes.proofRequired => l10n.errProofRequired,
  ErrorCodes.uploadNotFound => l10n.errUploadMissing,
  ErrorCodes.callInProgress => l10n.errCallInProgress,
  ErrorCodes.promoInvalid => l10n.errPromoInvalid,
  ErrorCodes.payoutAccountNotFound => l10n.errPayoutAccountMissing,
  'ERR_OFFER_NOT_ACTIVE' => l10n.errOfferNotActive,
  'ERR_OFFER_NOT_YOUR_TURN' => l10n.errOfferNotYourTurn,
  'ERR_OFFER_ALREADY_PENDING' => l10n.errOfferAlreadyPending,
  'ERR_PRICE_OUT_OF_RANGE' => l10n.errPriceOutOfRange,
  'ERR_LOCATION_UNAVAILABLE' => l10n.errLocationUnavailable,
  'ERR_NOT_AT_PICKUP' => l10n.errNotAtPickup,
  'ERR_RATING_WINDOW_CLOSED' => l10n.errRatingWindowClosed,
  'ERR_CHAT_CLOSED' => l10n.errChatClosed,
  'ERR_BLOCKED' => l10n.errBlocked,
  'ERR_VEHICLE_NOT_ALLOWED_IN_ZONE' => l10n.errVehicleNotAllowed,
  'ERR_PROVIDER_SUSPENDED' => l10n.errProviderSuspended,
  'ERR_IDENTITY_ALREADY_REGISTERED' => l10n.errIdentityAlreadyRegistered,
  'ERR_TRUSTED_CONTACT_LIMIT' => l10n.errTrustedContactLimit,
  'ERR_NO_ITEM_FLOAT' => l10n.errNoItemFloat,
  'ERR_REFERRAL_CODE_NOT_FOUND' => l10n.errReferralCodeNotFound,
  'ERR_REFERRAL_ALREADY_ATTRIBUTED' => l10n.errReferralAlreadyAttributed,
  'ERR_REFERRAL_SELF' => l10n.errReferralSelf,
  'ERR_REFERRAL_TOO_LATE' => l10n.errReferralTooLate,
  'ERR_DISPUTE_ALREADY_OPEN' => l10n.errDisputeAlreadyOpen,
  'ERR_DISPUTE_WINDOW_CLOSED' => l10n.errDisputeWindowClosed,
  'ERR_CONTENT_NOT_ALLOWED' => l10n.errContentNotAllowed,
  'ERR_CALL_WINDOW_CLOSED' => l10n.errCallWindowClosed,
  'ERR_PSTN_UNAVAILABLE' => l10n.errPstnUnavailable,
  'ERR_TICKET_CLOSED' => l10n.errTicketClosed,
  'ERR_ORG_ROLE_REQUIRED' => l10n.errOrgRoleRequired,
  'ERR_WORKER_NOT_ELIGIBLE' => l10n.errWorkerNotEligible,
  _ => null,
};

String _family(AppLocalizations l10n, String code) {
  if (code.endsWith('_NOT_FOUND')) return l10n.errNotFound;
  return switch (code) {
    ErrorCodes.invalidArgument ||
    'ERR_METHOD_NOT_ALLOWED' ||
    'ERR_IDEMPOTENCY_KEY_INVALID' ||
    'ERR_INTEGRITY_NONCE_INVALID' => l10n.errInvalidInput,
    'ERR_INTERNAL' || 'ERR_IDEMPOTENCY_IN_PROGRESS' => l10n.errTryAgain,
    _ => l10n.errUnknown,
  };
}
