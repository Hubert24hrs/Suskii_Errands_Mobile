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
  'txnInstantPayout' => l10n.txnInstantPayout,
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

String verificationStatusLabel(
  AppLocalizations l10n,
  VerificationStatus status,
) => switch (status) {
  VerificationStatus.unverified => l10n.verificationUnverified,
  VerificationStatus.pending => l10n.verificationPending,
  VerificationStatus.inReview => l10n.verificationInReview,
  VerificationStatus.verified => l10n.verificationVerified,
  VerificationStatus.rejected => l10n.verificationRejected,
  VerificationStatus.suspended => l10n.verificationSuspended,
  VerificationStatus.expired => l10n.verificationExpired,
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

String urgencyLabel(AppLocalizations l10n, Urgency urgency) =>
    switch (urgency) {
      Urgency.flexible => l10n.urgencyFlexible,
      Urgency.standard => l10n.urgencyStandard,
      Urgency.urgent => l10n.urgencyUrgent,
      Urgency.emergency => l10n.urgencyEmergency,
    };

String offerStatusLabel(AppLocalizations l10n, OfferStatus status) =>
    switch (status) {
      OfferStatus.pending => l10n.offersPendingStatus,
      OfferStatus.countered => l10n.offersCounter,
      OfferStatus.accepted => l10n.offersAcceptedStatus,
      OfferStatus.declined => l10n.offersDeclinedStatus,
      OfferStatus.withdrawn => l10n.offersWithdrawnStatus,
      OfferStatus.expired => l10n.offersExpired,
    };

/// Emergency-number labels arrive as localization keys from the country pack.
String emergencyNumberLabel(AppLocalizations l10n, String key) => switch (key) {
  'emergencyPolice' => l10n.emergencyPolice,
  'emergencyAmbulance' => l10n.emergencyAmbulance,
  _ => l10n.emergencyGeneral,
};

/// Request-cancellation reasons are localization keys sent to the server,
/// never free text.
String cancelReasonLabel(AppLocalizations l10n, String key) => switch (key) {
  'changedMind' => l10n.cancelReasonChangedMind,
  'priceTooHigh' => l10n.cancelReasonPriceTooHigh,
  'foundElsewhere' => l10n.cancelReasonFoundElsewhere,
  _ => l10n.cancelReasonOther,
};

String paymentMethodLabel(AppLocalizations l10n, PaymentMethod method) =>
    switch (method) {
      PaymentMethod.card => l10n.payMethodCard,
      PaymentMethod.bankTransfer => l10n.payMethodBankTransfer,
      PaymentMethod.mobileMoney => l10n.payMethodMobileMoney,
      PaymentMethod.ussd => l10n.payMethodUssd,
    };

/// Rating quick-tag keys → localized labels.
String ratingTagLabel(AppLocalizations l10n, String key) => switch (key) {
  'ratingTagPunctual' => l10n.ratingTagPunctual,
  'ratingTagCareful' => l10n.ratingTagCareful,
  'ratingTagCommunicative' => l10n.ratingTagCommunicative,
  'ratingTagProfessional' => l10n.ratingTagProfessional,
  'ratingTagSlow' => l10n.ratingTagSlow,
  _ => l10n.ratingTagRude,
};

String disputeStatusLabel(AppLocalizations l10n, DisputeStatus status) =>
    switch (status) {
      DisputeStatus.open => l10n.disputeStatusOpen,
      DisputeStatus.inReview => l10n.disputeStatusInReview,
      DisputeStatus.resolved => l10n.disputeStatusResolved,
      DisputeStatus.rejected => l10n.disputeStatusRejected,
    };

/// Dispute reasons are localization keys sent to the server, never free text.
String disputeReasonLabel(AppLocalizations l10n, String key) => switch (key) {
  'disputeReasonNotDelivered' => l10n.disputeReasonNotDelivered,
  'disputeReasonDamaged' => l10n.disputeReasonDamaged,
  'disputeReasonLate' => l10n.disputeReasonLate,
  _ => l10n.disputeReasonOther,
};

String ticketStatusLabel(AppLocalizations l10n, SupportTicketStatus status) =>
    switch (status) {
      SupportTicketStatus.open => l10n.supportStatusOpen,
      SupportTicketStatus.awaitingUser => l10n.supportStatusAwaitingUser,
      SupportTicketStatus.resolved => l10n.supportStatusResolved,
      SupportTicketStatus.closed => l10n.supportStatusClosed,
    };

/// Business-role labels (M6 business console).
String businessRoleLabel(AppLocalizations l10n, BusinessRole role) =>
    switch (role) {
      BusinessRole.owner => l10n.orgRoleOwner,
      BusinessRole.dispatcher => l10n.orgRoleDispatcher,
      BusinessRole.worker => l10n.orgRoleWorker,
    };

/// Earnings-goal period labels (M6 provider tools).
String goalPeriodLabel(AppLocalizations l10n, GoalPeriod period) =>
    switch (period) {
      GoalPeriod.weekly => l10n.toolsGoalWeekly,
      GoalPeriod.monthly => l10n.toolsGoalMonthly,
    };

/// Weekday short labels; [dayOfWeek] is 1 = Monday … 7 = Sunday.
String weekdayLabel(AppLocalizations l10n, int dayOfWeek) =>
    switch (dayOfWeek) {
      1 => l10n.toolsDayMon,
      2 => l10n.toolsDayTue,
      3 => l10n.toolsDayWed,
      4 => l10n.toolsDayThu,
      5 => l10n.toolsDayFri,
      6 => l10n.toolsDaySat,
      _ => l10n.toolsDaySun,
    };
