import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_l10n/suskii_l10n.dart';

/// Maps a stable error code to its localized message. Never show raw
/// exception text to users.
String localizedError(AppLocalizations l10n, Object error) {
  if (error is! AppError) return l10n.errUnknown;
  return switch (error.code) {
    ErrorCodes.network => l10n.errNetwork,
    ErrorCodes.forceUpdateRequired => l10n.errForceUpdateRequired,
    ErrorCodes.countryDisabled => l10n.errCountryDisabled,
    ErrorCodes.unauthenticated => l10n.errUnauthenticated,
    ErrorCodes.permissionDenied => l10n.errPermissionDenied,
    ErrorCodes.providerNotVerified => l10n.errProviderNotVerified,
    ErrorCodes.providerBusyAsCustomer => l10n.errProviderBusyAsCustomer,
    ErrorCodes.kycExpired => l10n.errKycExpired,
    ErrorCodes.selfieCheckRequired => l10n.errSelfieCheckRequired,
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
    ErrorCodes.unsupportedLanguage => l10n.errUnsupportedLanguage,
    ErrorCodes.invalidState => l10n.errInvalidState,
    ErrorCodes.proofRequired => l10n.errProofRequired,
    ErrorCodes.callInProgress => l10n.errCallInProgress,
    ErrorCodes.promoInvalid => l10n.errPromoInvalid,
    _ => l10n.errUnknown,
  };
}
