/// Status and type enums shared across every Suskii surface.
/// Names mirror the master spec; JSON wire format is lower snake_case via
/// `@JsonValue` — the same values Postgres and the Supabase-generated types
/// use (contracts v1, review item N.6).
library;

import 'package:json_annotation/json_annotation.dart';

enum UserMode {
  @JsonValue('customer')
  customer,
  @JsonValue('provider')
  provider,
}

enum CountryStatus {
  @JsonValue('disabled')
  disabled,
  @JsonValue('beta')
  beta,
  @JsonValue('live')
  live,
}

enum Urgency {
  @JsonValue('flexible')
  flexible,
  @JsonValue('standard')
  standard,
  @JsonValue('urgent')
  urgent,
  @JsonValue('emergency')
  emergency,
}

enum TrustLevel {
  @JsonValue('new')
  new_,
  @JsonValue('verified')
  verified,
  @JsonValue('trusted')
  trusted,
  @JsonValue('elite')
  elite,
}

enum VehicleType {
  @JsonValue('walking')
  walking,
  @JsonValue('bicycle')
  bicycle,
  @JsonValue('motorcycle')
  motorcycle,
  @JsonValue('tricycle')
  tricycle,
  @JsonValue('car')
  car,
  @JsonValue('van')
  van,
  @JsonValue('truck')
  truck,
}

enum VerificationStatus {
  @JsonValue('unverified')
  unverified,
  @JsonValue('pending')
  pending,
  @JsonValue('in_review')
  inReview,
  @JsonValue('verified')
  verified,
  @JsonValue('rejected')
  rejected,
  @JsonValue('suspended')
  suspended,
  @JsonValue('expired')
  expired,
}

/// The 20 job lifecycle states from the master spec, in canonical order.
enum JobStatus {
  @JsonValue('draft')
  draft,
  @JsonValue('published')
  published,
  @JsonValue('offers_received')
  offersReceived,
  @JsonValue('negotiating')
  negotiating,
  @JsonValue('agreed')
  agreed,
  @JsonValue('payment_pending')
  paymentPending,
  @JsonValue('paid_held')
  paidHeld,
  @JsonValue('assigned')
  assigned,
  @JsonValue('en_route')
  enRoute,
  @JsonValue('arrived')
  arrived,
  @JsonValue('in_progress')
  inProgress,
  @JsonValue('completed_by_provider')
  completedByProvider,
  @JsonValue('confirmed')
  confirmed,
  @JsonValue('settlement_pending')
  settlementPending,
  @JsonValue('settled')
  settled,
  @JsonValue('closed')
  closed,
  @JsonValue('cancelled')
  cancelled,
  @JsonValue('expired')
  expired,
  @JsonValue('disputed')
  disputed,
  @JsonValue('refunded')
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

enum OfferStatus {
  @JsonValue('pending')
  pending,
  @JsonValue('countered')
  countered,
  @JsonValue('accepted')
  accepted,
  @JsonValue('declined')
  declined,
  @JsonValue('expired')
  expired,
  @JsonValue('withdrawn')
  withdrawn,
}

enum PaymentStatus {
  @JsonValue('unpaid')
  unpaid,
  @JsonValue('pending')
  pending,
  @JsonValue('held')
  held,
  @JsonValue('failed')
  failed,
  @JsonValue('refunded')
  refunded,
  @JsonValue('partially_refunded')
  partiallyRefunded,
}

/// Customer-facing payment rails; per-country availability comes from the
/// country pack (Flutterwave primary in wave-1 markets).
enum PaymentMethod {
  @JsonValue('card')
  card,
  @JsonValue('bank_transfer')
  bankTransfer,
  @JsonValue('mobile_money')
  mobileMoney,
  @JsonValue('ussd')
  ussd,
}

/// Lifecycle of a masked in-app call (LiveKit behind a vendor-neutral
/// adapter). Calls exist only between the two participants of a job.
enum CallState {
  @JsonValue('connecting')
  connecting,
  @JsonValue('ringing')
  ringing,
  @JsonValue('active')
  active,
  @JsonValue('ended')
  ended,
  @JsonValue('failed')
  failed,
}

enum SosStatus {
  @JsonValue('active')
  active,
  @JsonValue('resolved')
  resolved,
}

/// Dispute-center lifecycle (M5). Payouts are frozen while a dispute is open
/// or in review.
enum DisputeStatus {
  @JsonValue('open')
  open,
  @JsonValue('in_review')
  inReview,
  @JsonValue('resolved')
  resolved,
  @JsonValue('rejected')
  rejected,
}

/// Help-center ticket lifecycle (M5). `awaitingUser` is set when support (or
/// the AI triage) has replied and the ball is with the user.
enum SupportTicketStatus {
  @JsonValue('open')
  open,
  @JsonValue('awaiting_user')
  awaitingUser,
  @JsonValue('resolved')
  resolved,
  @JsonValue('closed')
  closed,
}

enum ReferralCommissionStatus {
  @JsonValue('pending')
  pending,
  @JsonValue('earned')
  earned,
  @JsonValue('holding')
  holding,
  @JsonValue('available')
  available,
  @JsonValue('reversed')
  reversed,
}

enum ChatMessageType {
  @JsonValue('text')
  text,
  @JsonValue('image')
  image,
  @JsonValue('voice_note')
  voiceNote,
  @JsonValue('location')
  location,
  @JsonValue('offer_card')
  offerCard,
  @JsonValue('system')
  system,
}

enum WalletTransactionKind {
  @JsonValue('credit')
  credit,
  @JsonValue('debit')
  debit,
  @JsonValue('hold')
  hold,
  @JsonValue('release')
  release,
  @JsonValue('refund')
  refund,
  @JsonValue('payout')
  payout,
  @JsonValue('referral')
  referral,
  @JsonValue('tip')
  tip,
  @JsonValue('item_float')
  itemFloat,
}

enum WalletTransactionStatus {
  @JsonValue('pending')
  pending,
  @JsonValue('completed')
  completed,
  @JsonValue('failed')
  failed,
  @JsonValue('reversed')
  reversed,
}

enum ProviderKind {
  @JsonValue('individual')
  individual,
  @JsonValue('business')
  business,
}

enum BusinessRole {
  @JsonValue('owner')
  owner,
  @JsonValue('dispatcher')
  dispatcher,
  @JsonValue('worker')
  worker,
}

/// Individual KYC/verification steps from the master spec. `customerFacial`
/// is the customer flow; the rest belong to provider onboarding.
enum KycStepKind {
  @JsonValue('customer_facial')
  customerFacial,
  @JsonValue('government_id')
  governmentId,
  @JsonValue('provider_facial')
  providerFacial,
  @JsonValue('id_document_capture')
  idDocumentCapture,
  @JsonValue('police_clearance')
  policeClearance,
  @JsonValue('address')
  address,
  @JsonValue('guarantor')
  guarantor,
  @JsonValue('payout_account')
  payoutAccount,
  @JsonValue('vehicle_documents')
  vehicleDocuments,
  @JsonValue('credentials')
  credentials,
}

enum KycStepStatus {
  @JsonValue('not_started')
  notStarted,
  @JsonValue('consent_pending')
  consentPending,
  @JsonValue('in_progress')
  inProgress,
  @JsonValue('in_review')
  inReview,
  @JsonValue('verified')
  verified,
  @JsonValue('rejected')
  rejected,
  @JsonValue('expired')
  expired,
}

/// Server-style outcome of an identity-verification vendor call
/// (liveness capture). `retry` means the user may try again; `failed`
/// carries a localizable reason key.
enum IdentityCheckOutcome {
  @JsonValue('success')
  success,
  @JsonValue('retry')
  retry,
  @JsonValue('failed')
  failed,
}

/// Confidence of a server-computed [PriceBand] — depends on sample size.
enum PriceBandConfidence {
  @JsonValue('low')
  low,
  @JsonValue('medium')
  medium,
  @JsonValue('high')
  high,
}

/// What a [PriceBand] is derived from (ai-design §9): a `rules` band is a
/// rough guide until enough completed jobs exist for a `history` band.
enum PriceBandBasis {
  @JsonValue('rules')
  rules,
  @JsonValue('history')
  history,
}

enum ConciergeRole {
  @JsonValue('user')
  user,
  @JsonValue('assistant')
  assistant,
  @JsonValue('system')
  system,
}

/// What the concierge assistant proposes the UI do next, carried on assistant
/// messages: the publish card (user's tap calls publishRequest), the offers
/// board, the SOS card, or a handoff to the prefilled request form.
enum ConciergeProposedAction {
  @JsonValue('none')
  none,
  @JsonValue('show_publish_card')
  showPublishCard,
  @JsonValue('show_offer_comparison')
  showOfferComparison,
  @JsonValue('show_sos_card')
  showSosCard,
  @JsonValue('handoff_to_form')
  handoffToForm,
}

enum VoiceEventKind {
  @JsonValue('session_state')
  sessionState,
  @JsonValue('transcript')
  transcript,
  @JsonValue('assistant_audio')
  assistantAudio,
}

enum VoiceSessionState {
  @JsonValue('connecting')
  connecting,
  @JsonValue('listening')
  listening,
  @JsonValue('thinking')
  thinking,
  @JsonValue('speaking')
  speaking,
  @JsonValue('ended')
  ended,
}
