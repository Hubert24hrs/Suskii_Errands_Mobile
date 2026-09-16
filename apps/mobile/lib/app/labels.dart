import 'package:suskii_domain/suskii_domain.dart';
import 'package:suskii_l10n/suskii_l10n.dart';

/// Enum/key → localized label helpers. Labels live in ARB files only.
String jobStatusLabel(AppLocalizations l10n, JobStatus status) =>
    switch (status) {
      JobStatus.draft => l10n.statusDraft,
      JobStatus.published => l10n.statusPublished,
      JobStatus.offersReceived => l10n.statusOffersReceived,
      JobStatus.negotiating => l10n.statusNegotiating,
      JobStatus.agreed => l10n.statusAgreed,
      JobStatus.paymentPending => l10n.statusPaymentPending,
      JobStatus.paidHeld => l10n.statusPaidHeld,
      JobStatus.assigned => l10n.statusAssigned,
      JobStatus.enRoute => l10n.statusEnRoute,
      JobStatus.arrived => l10n.statusArrived,
      JobStatus.inProgress => l10n.statusInProgress,
      JobStatus.completedByProvider => l10n.statusCompletedByProvider,
      JobStatus.confirmed => l10n.statusConfirmed,
      JobStatus.settlementPending => l10n.statusSettlementPending,
      JobStatus.settled => l10n.statusSettled,
      JobStatus.closed => l10n.statusClosed,
      JobStatus.cancelled => l10n.statusCancelled,
      JobStatus.expired => l10n.statusExpired,
      JobStatus.disputed => l10n.statusDisputed,
      JobStatus.refunded => l10n.statusRefunded,
    };

String categoryLabel(AppLocalizations l10n, String labelKey) =>
    switch (labelKey) {
      'catErrandsDelivery' => l10n.catErrandsDelivery,
      'catShopping' => l10n.catShopping,
      'catCleaningLaundry' => l10n.catCleaningLaundry,
      'catMoving' => l10n.catMoving,
      'catRepairs' => l10n.catRepairs,
      'catPersonalAssistance' => l10n.catPersonalAssistance,
      'catDocumentDelivery' => l10n.catDocumentDelivery,
      'catFoodPickup' => l10n.catFoodPickup,
      'catTransportation' => l10n.catTransportation,
      'catTechBusiness' => l10n.catTechBusiness,
      'catEventAssistance' => l10n.catEventAssistance,
      _ => l10n.catCustom,
    };

String documentTypeLabel(AppLocalizations l10n, String key) => switch (key) {
  'docPoliceClearance' => l10n.docPoliceClearance,
  _ => key,
};

String transactionLabel(AppLocalizations l10n, String? key) => switch (key) {
  'txnPayoutCleaning' => l10n.txnPayoutCleaning,
  'txnTip' => l10n.txnTip,
  'txnReferral' => l10n.txnReferral,
  'txnRefundItemFloat' => l10n.txnRefundItemFloat,
  'txnWithdrawal' => l10n.txnWithdrawal,
  'txnReferralWithdrawal' => l10n.txnReferralWithdrawal,
  _ => key ?? '',
};

String kycStepKindLabel(AppLocalizations l10n, KycStepKind kind) =>
    switch (kind) {
      KycStepKind.customerFacial => l10n.kycStepCustomerFacial,
      KycStepKind.governmentId => l10n.kycStepGovernmentId,
      KycStepKind.providerFacial => l10n.kycStepProviderFacial,
      KycStepKind.idDocumentCapture => l10n.kycStepIdDocumentCapture,
      KycStepKind.policeClearance => l10n.kycStepPoliceClearance,
      KycStepKind.address => l10n.kycStepAddress,
      KycStepKind.guarantor => l10n.kycStepGuarantor,
      KycStepKind.payoutAccount => l10n.kycStepPayoutAccount,
      KycStepKind.vehicleDocuments => l10n.kycStepVehicleDocuments,
      KycStepKind.credentials => l10n.kycStepCredentials,
    };

String kycStepKindBody(AppLocalizations l10n, KycStepKind kind) =>
    switch (kind) {
      KycStepKind.customerFacial => l10n.kycStepCustomerFacialBody,
      KycStepKind.governmentId => l10n.kycStepGovernmentIdBody,
      KycStepKind.providerFacial => l10n.kycStepProviderFacialBody,
      KycStepKind.idDocumentCapture => l10n.kycStepIdDocumentCaptureBody,
      KycStepKind.policeClearance => l10n.kycStepPoliceClearanceBody,
      KycStepKind.address => l10n.kycStepAddressBody,
      KycStepKind.guarantor => l10n.kycStepGuarantorBody,
      KycStepKind.payoutAccount => l10n.kycStepPayoutAccountBody,
      KycStepKind.vehicleDocuments => l10n.kycStepVehicleDocumentsBody,
      KycStepKind.credentials => l10n.kycStepCredentialsBody,
    };

String kycStepStatusLabel(AppLocalizations l10n, KycStepStatus status) =>
    switch (status) {
      KycStepStatus.notStarted => l10n.kycStatusNotStarted,
      KycStepStatus.consentPending => l10n.kycStatusConsentPending,
      KycStepStatus.inProgress => l10n.kycStatusInProgress,
      KycStepStatus.inReview => l10n.verificationInReview,
      KycStepStatus.verified => l10n.verificationVerified,
      KycStepStatus.rejected => l10n.verificationRejected,
      KycStepStatus.expired => l10n.verificationExpired,
    };

String idTypeLabel(AppLocalizations l10n, String idType) => switch (idType) {
  'nin' => l10n.idNin,
  'bvn' => l10n.idBvn,
  'votersCard' => l10n.idVotersCard,
  'driversLicence' => l10n.idDriversLicence,
  'passport' => l10n.idPassport,
  _ => idType,
};

String vehicleTypeLabel(AppLocalizations l10n, VehicleType type) =>
    switch (type) {
      VehicleType.walking => l10n.vehicleWalking,
      VehicleType.bicycle => l10n.vehicleBicycle,
      VehicleType.motorcycle => l10n.vehicleMotorcycle,
      VehicleType.tricycle => l10n.vehicleTricycle,
      VehicleType.car => l10n.vehicleCar,
      VehicleType.van => l10n.vehicleVan,
      VehicleType.truck => l10n.vehicleTruck,
    };

/// KYC rejection reasons arrive as localization keys, never free text.
String kycRejectionReasonLabel(AppLocalizations l10n, String? key) =>
    switch (key) {
      'kycRejectPoliceClearanceExpired' => l10n.kycRejectPoliceClearanceExpired,
      _ => key ?? l10n.errUnknown,
    };
