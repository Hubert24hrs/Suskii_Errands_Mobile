import '../entities/bootstrap.dart';
import '../entities/catalog.dart';
import '../entities/chat.dart';
import '../entities/concierge.dart';
import '../entities/notification.dart';
import '../entities/offer.dart';
import '../entities/referral.dart';
import '../entities/request.dart';
import '../entities/user.dart';
import '../entities/verification.dart';
import '../entities/wallet.dart';
import '../enums.dart';
import '../geo_point.dart';
import '../money.dart';

/// ---------------------------------------------------------------------------
/// Repository interfaces — one per feature. Screens depend ONLY on these.
/// Mock implementations live in packages/suskii_data; Supabase implementations
/// arrive when official contracts land (milestone M9).
///
/// Convention: methods that change money, state, verification, ratings or
/// permissions are ACTION REQUESTS — the server validates, mutates and returns
/// the new state. Clients never assign statuses or amounts locally.
///
/// Every mutating method takes a required `idempotencyKey` (UUIDv7, see
/// `newIdempotencyKey()` in suskii_core): one key per user intent, reused
/// only when retrying that same intent. The server deduplicates on it.
/// ---------------------------------------------------------------------------

enum AuthStatus { unknown, signedOut, signedIn }

class AuthState {
  const AuthState({required this.status, this.user});

  final AuthStatus status;
  final AppUser? user;
}

class CreateRequestInput {
  const CreateRequestInput({
    required this.categoryId,
    required this.description,
    required this.pickup,
    this.destination,
    this.isCustomCategory = false,
    this.mediaPaths = const <String>[],
    this.urgency = Urgency.standard,
    this.scheduledAt,
    this.preferredPrice,
    this.itemFloat,
    this.declaredValue,
  });

  final String categoryId;
  final bool isCustomCategory;
  final String description;
  final List<String> mediaPaths;
  final PlaceRef pickup;
  final PlaceRef? destination;
  final Urgency urgency;
  final DateTime? scheduledAt;
  final Money? preferredPrice;
  final Money? itemFloat;
  final Money? declaredValue;
}

abstract interface class BootstrapRepository {
  Future<AppBootstrap> getBootstrap();
  Stream<AppNotification> watchNotifications();
}

abstract interface class AuthRepository {
  Stream<AuthState> authStateChanges();
  Future<void> requestPhoneOtp(String phoneE164);
  Future<AppUser> verifyPhoneOtp(String phoneE164, String code);
  Future<void> requestEmailOtp(String email);
  Future<AppUser> verifyEmailOtp(String email, String code);

  /// Social sign-in placeholders. Throw AppError(ERR_FEATURE_UNAVAILABLE)
  /// until the providers are configured.
  Future<AppUser> signInWithGoogle();
  Future<AppUser> signInWithApple();
  Future<void> signOut();
}

abstract interface class UserRepository {
  Future<AppUser> getProfile();
  Stream<AppUser> watchProfile();

  /// Throws AppError(ERR_PROVIDER_NOT_VERIFIED) when switching to provider
  /// mode without completed provider KYC.
  Future<UserMode> setActiveMode(
    UserMode mode, {
    required String idempotencyKey,
  });
}

abstract interface class RequestRepository {
  Future<List<JobRequest>> getMyActiveJobs();
  Future<List<JobRequest>> getMyRequestHistory({
    String? cursor,
    int limit = 20,
  });
  Stream<JobRequest> watchJob(String jobId);

  /// Always creates a DRAFT. Unverified customers may draft (and use the
  /// concierge); verification gates publishing, not creating (review 2.14).
  Future<JobRequest> createRequest(
    CreateRequestInput input, {
    required String idempotencyKey,
  });

  /// Transitions DRAFT → PUBLISHED. Throws AppError(ERR_VERIFICATION_REQUIRED)
  /// when the customer's verification is not VERIFIED, so the UI can route to
  /// the verification flow instead of showing a generic denial.
  Future<JobRequest> publishRequest(
    String jobId, {
    required String idempotencyKey,
  });

  /// Cancellation is a server decision (fees depend on state and timing).
  Future<JobRequest> cancelRequest(
    String jobId,
    String reasonKey, {
    required String idempotencyKey,
  });
}

abstract interface class OfferRepository {
  Stream<List<Offer>> watchOffers(String requestId);
  Future<Offer> acceptOffer(String offerId, {required String idempotencyKey});
  Future<Offer> declineOffer(String offerId, {required String idempotencyKey});
  Future<Offer> counterOffer({
    required String offerId,
    required Money amount,
    required String idempotencyKey,
    String? message,
  });

  /// Author pulls a pending offer before acceptance (offer machine #5).
  Future<Offer> withdrawOffer(String offerId, {required String idempotencyKey});
}

abstract interface class ProviderRepository {
  Future<ProviderHomeSummary> getHomeSummary();
  Stream<List<JobRequest>> watchNearbyRequests();
  Future<List<Offer>> getMyOffers();
  Future<Offer> submitOffer({
    required String requestId,
    required Money amount,
    required String idempotencyKey,
    String? message,
  });

  /// Throws AppError(ERR_KYC_EXPIRED / ERR_SELFIE_CHECK_REQUIRED /
  /// ERR_PROVIDER_BUSY_AS_CUSTOMER) when going online is not allowed.
  Future<bool> setOnline(bool online, {required String idempotencyKey});
}

abstract interface class JobProgressRepository {
  /// Provider requests a status change; the server runs the state machine.
  Future<JobRequest> requestStatusChange(
    String jobId,
    JobStatus target, {
    required String idempotencyKey,
  });

  /// Customer confirms completion (may be auto-confirmed server-side too).
  Future<JobRequest> confirmCompletion(
    String jobId, {
    required String idempotencyKey,
  });

  /// PIN verification for pickup/delivery. Server-side attempt limits apply:
  /// a wrong PIN consumes an attempt, but a retry with the SAME
  /// [idempotencyKey] replays the earlier result without spending another.
  Future<bool> verifyHandoverPin(
    String jobId,
    String pin, {
    required String idempotencyKey,
  });
}

abstract interface class TrackingRepository {
  /// Live provider location for an active job (Realtime Broadcast on the
  /// backend; sampled mock ticks for now).
  Stream<GeoPoint> watchProviderLocation(String jobId);
}

abstract interface class ChatRepository {
  Stream<List<ChatMessage>> watchMessages(String jobId);
  Future<ChatMessage> sendMessage({
    required String jobId,
    required ChatMessageType type,
    required String idempotencyKey,
    String? text,
    String? mediaPath,
    GeoPoint? location,
  });
}

abstract interface class WalletRepository {
  Future<WalletSummary> getSummary();
  Future<List<WalletTransaction>> getTransactions({
    String? cursor,
    int limit = 20,
  });

  /// Withdrawals require KYC + name-matched payout account (server-enforced).
  Future<WalletTransaction> requestWithdrawal(
    Money amount, {
    required String idempotencyKey,
  });
}

abstract interface class ReferralRepository {
  Future<ReferralSummary> getSummary();
  Future<WalletTransaction> requestWithdrawal(
    Money amount, {
    required String idempotencyKey,
  });
}

/// AI concierge (text + voice). The concierge structures a request via
/// server-side slot filling; the user confirms in the UI before anything is
/// published. Screens never talk to the model vendor directly.
///
/// The concierge holds NO publish capability (review M3.1): when the draft is
/// complete the server has already created the underlying draft [JobRequest]
/// (`ConciergeDraft.requestId`) and the publish card calls
/// [RequestRepository.publishRequest] like any other draft.
abstract interface class ConciergeRepository {
  Future<ConciergeConversation> startConversation({
    required String idempotencyKey,
  });

  /// Full message list, re-emitted whenever a message or the attached
  /// structured draft changes.
  Stream<List<ConciergeMessage>> watchMessages(String conversationId);

  /// Streams assistant reply chunks. The complete message — including any
  /// updated [ConciergeDraft] — is then observable via [watchMessages].
  Stream<String> sendMessage(
    String conversationId,
    String text, {
    required String idempotencyKey,
  });
}

abstract interface class CatalogRepository {
  Future<List<ServiceCategory>> getCategories();
  Future<CountryPack> getCountryPack(String countryCode);

  /// Server-computed P25/P50/P75 price band for a category — an advisory
  /// hint next to the preferred-price field. Never used to set prices.
  Future<PriceBand> getPriceBand({required String categoryId, GeoPoint? near});
}

/// ---------------------------------------------------------------------------
/// Verification / KYC (milestone M2)
/// ---------------------------------------------------------------------------

class LivenessSession {
  const LivenessSession({required this.sessionId, required this.expiresAt});

  final String sessionId;
  final DateTime expiresAt;
}

class LivenessResult {
  const LivenessResult({required this.outcome, this.reasonKey});

  final IdentityCheckOutcome outcome;
  final String? reasonKey;
}

/// Vendor-neutral identity-verification adapter for ON-DEVICE capture only.
/// The Smile ID SDK (or alternative picked by spike S-05) plugs in behind
/// this; screens and repositories never talk to a vendor SDK directly.
///
/// Government-ID lookup is deliberately NOT here (review C.2): it is
/// server-side via `VerificationRepository.submitIdLookup`, which returns an
/// outcome + reason key only — the device must never become a
/// NIN → full-name lookup oracle.
abstract interface class IdentityVerificationAdapter {
  Future<LivenessSession> startLivenessSession();
  Future<LivenessResult> captureLiveness(String sessionId);
}

/// Customer facial-verification flow (phone OTP → consent → liveness + ID
/// lookup → result). All methods are action requests: the repository decides
/// outcomes and returns the new session state.
abstract interface class VerificationRepository {
  Future<VerificationSession?> getCustomerVerification();
  Stream<VerificationSession?> watchCustomerVerification();

  /// Records explicit consent for biometric processing (separate from
  /// criminal-record consent on the provider side).
  Future<VerificationSession> giveBiometricConsent({
    required String idempotencyKey,
  });

  /// Throws AppError(ERR_CONSENT_REQUIRED) when consent was not given.
  Future<VerificationSession> startFacialVerification({
    required String idempotencyKey,
  });

  /// Throws AppError(ERR_KYC_STEP_INVALID) when the session is not in a
  /// submittable state.
  Future<VerificationSession> submitIdLookup(
    String sessionId,
    String idType,
    String idNumber, {
    required String idempotencyKey,
  });
}

/// Provider KYC: onboarding, per-step submission, payout-account name match
/// and final submission for Verification Officer review.
abstract interface class ProviderKycRepository {
  Future<ProviderKycProfile> getKycProfile();
  Stream<ProviderKycProfile> watchKycProfile();
  Future<ProviderKycProfile> saveOnboarding(
    ProviderOnboardingInput input, {
    required String idempotencyKey,
  });

  /// [input] is typed per [kind]: IdDocumentInput (governmentId,
  /// idDocumentCapture — capture requires uploadRef), String liveness
  /// sessionId (providerFacial), PoliceClearanceInput, AddressInput,
  /// GuarantorInput, PayoutAccountInput, VehicleDocumentsInput,
  /// CredentialsInput. Throws AppError(ERR_KYC_STEP_INVALID) on a wrong
  /// input type or an illegal state transition.
  Future<ProviderKycProfile> submitStep(
    KycStepKind kind,
    Object input, {
    required String idempotencyKey,
  });

  /// Server-style account-name lookup against the verified identity.
  /// Read-only: does not mutate the profile.
  Future<PayoutAccountResult> resolvePayoutAccount(PayoutAccountInput input);

  /// Throws AppError(ERR_KYC_INCOMPLETE) unless every required step is
  /// verified or in review (vehicle documents are required only for
  /// motorized vehicles).
  Future<ProviderKycProfile> submitForReview({required String idempotencyKey});
}

/// ---------------------------------------------------------------------------
/// Voice concierge (milestone M3, OD-17)
/// ---------------------------------------------------------------------------

class VoiceSession {
  const VoiceSession({
    required this.sessionId,
    required this.conversationId,
    required this.language,
  });

  final String sessionId;
  final String conversationId;
  final String language;
}

class VoiceEvent {
  const VoiceEvent({required this.kind, this.state, this.text});

  final VoiceEventKind kind;

  /// Present on [VoiceEventKind.sessionState] events.
  final VoiceSessionState? state;

  /// Present on [VoiceEventKind.transcript] events.
  final String? text;
}

/// Vendor-neutral voice concierge adapter (Gemini Live / LiveKit arrive
/// later behind this). OD-17: per-language availability comes from the
/// bootstrap (`AppBootstrap.voiceLanguages`); adapters throw
/// AppError(ERR_UNSUPPORTED_LANGUAGE) for unavailable languages (e.g. `pcm`
/// if the Pidgin voice gate fails) so the UI falls back to the text
/// concierge.
abstract interface class VoiceConciergeAdapter {
  Future<VoiceSession> startSession(String conversationId, {String language});

  /// Transcript, assistant-audio and session-state events for a session.
  Stream<VoiceEvent> events(String sessionId);

  /// Streams a microphone audio chunk. Stubbed until the vendor lands.
  Future<void> sendAudio(String sessionId, List<int> audioChunk);

  Future<void> endSession(String sessionId);
}
