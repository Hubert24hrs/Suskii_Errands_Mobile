/// Status and type enums shared across every Suskii surface.
/// Names mirror the master spec; JSON wire format uses the camelCase `.name`.
library;

enum UserMode { customer, provider }

enum CountryStatus { disabled, beta, live }

enum Urgency { flexible, standard, urgent, emergency }

enum TrustLevel { new_, verified, trusted, elite }

enum VehicleType { walking, bicycle, motorcycle, tricycle, car, van, truck }

enum VerificationStatus {
  unverified,
  pending,
  inReview,
  verified,
  rejected,
  suspended,
  expired,
}

/// The 20 job lifecycle states from the master spec, in canonical order.
enum JobStatus {
  draft,
  published,
  offersReceived,
  negotiating,
  agreed,
  paymentPending,
  paidHeld,
  assigned,
  enRoute,
  arrived,
  inProgress,
  completedByProvider,
  confirmed,
  settlementPending,
  settled,
  closed,
  cancelled,
  expired,
  disputed,
  refunded;

  bool get isTerminal =>
      this == JobStatus.closed ||
      this == JobStatus.cancelled ||
      this == JobStatus.expired ||
      this == JobStatus.refunded;

  /// States where the job banner must stay visible across both app modes.
  bool get needsAttention =>
      this == JobStatus.agreed ||
      this == JobStatus.paymentPending ||
      this == JobStatus.paidHeld ||
      this == JobStatus.assigned ||
      this == JobStatus.enRoute ||
      this == JobStatus.arrived ||
      this == JobStatus.inProgress ||
      this == JobStatus.completedByProvider ||
      this == JobStatus.disputed;
}

enum OfferStatus { pending, countered, accepted, declined, expired, withdrawn }

enum PaymentStatus {
  unpaid,
  pending,
  held,
  failed,
  refunded,
  partiallyRefunded,
}

enum ReferralCommissionStatus { pending, earned, holding, available, reversed }

enum ChatMessageType { text, image, voiceNote, location, offerCard, system }

enum WalletTransactionKind {
  credit,
  debit,
  hold,
  release,
  refund,
  payout,
  referral,
  tip,
  itemFloat,
}

enum WalletTransactionStatus { pending, completed, failed, reversed }

enum ProviderKind { individual, business }

enum BusinessRole { owner, dispatcher, worker }

/// Individual KYC/verification steps from the master spec. `customerFacial`
/// is the customer flow; the rest belong to provider onboarding.
enum KycStepKind {
  customerFacial,
  governmentId,
  providerFacial,
  idDocumentCapture,
  policeClearance,
  address,
  guarantor,
  payoutAccount,
  vehicleDocuments,
  credentials,
}

enum KycStepStatus {
  notStarted,
  consentPending,
  inProgress,
  inReview,
  verified,
  rejected,
  expired,
}

/// Server-style outcome of an identity-verification vendor call
/// (liveness capture, government-ID match). `retry` means the user may
/// try again; `failed` carries a localizable [reasonKey].
enum IdentityCheckOutcome { success, retry, failed }
