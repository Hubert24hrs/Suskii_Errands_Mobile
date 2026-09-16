import '../entities/bootstrap.dart';
import '../entities/catalog.dart';
import '../entities/chat.dart';
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
  Future<UserMode> setActiveMode(UserMode mode);
}

abstract interface class RequestRepository {
  Future<List<JobRequest>> getMyActiveJobs();
  Future<List<JobRequest>> getMyRequestHistory({
    String? cursor,
    int limit = 20,
  });
  Stream<JobRequest> watchJob(String jobId);
  Future<JobRequest> createRequest(CreateRequestInput input);

  /// Cancellation is a server decision (fees depend on state and timing).
  Future<JobRequest> cancelRequest(String jobId, String reasonKey);
}

abstract interface class OfferRepository {
  Stream<List<Offer>> watchOffers(String requestId);
  Future<Offer> acceptOffer(String offerId);
  Future<Offer> declineOffer(String offerId);
  Future<Offer> counterOffer({
    required String offerId,
    required Money amount,
    String? message,
  });
}

abstract interface class ProviderRepository {
  Future<ProviderHomeSummary> getHomeSummary();
  Stream<List<JobRequest>> watchNearbyRequests();
  Future<List<Offer>> getMyOffers();
  Future<Offer> submitOffer({
    required String requestId,
    required Money amount,
    String? message,
  });

  /// Throws AppError(ERR_KYC_EXPIRED / ERR_SELFIE_CHECK_REQUIRED /
  /// ERR_PROVIDER_BUSY_AS_CUSTOMER) when going online is not allowed.
  Future<bool> setOnline(bool online);
}

abstract interface class JobProgressRepository {
  /// Provider requests a status change; the server runs the state machine.
  Future<JobRequest> requestStatusChange(String jobId, JobStatus target);

  /// Customer confirms completion (may be auto-confirmed server-side too).
  Future<JobRequest> confirmCompletion(String jobId);

  /// PIN verification for pickup/delivery. Server-side attempt limits apply.
  Future<bool> verifyHandoverPin(String jobId, String pin);
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
  Future<WalletTransaction> requestWithdrawal(Money amount);
}

abstract interface class ReferralRepository {
  Future<ReferralSummary> getSummary();
  Future<WalletTransaction> requestWithdrawal(Money amount);
}

/// AI concierge (text + voice). Full surface arrives with milestone M3;
/// the interface is defined now so screens never talk to a vendor SDK directly.
abstract interface class ConciergeRepository {
  /// Streams assistant reply chunks for a concierge conversation.
  Stream<String> sendMessage(String conversationId, String text);
}

abstract interface class CatalogRepository {
  Future<List<ServiceCategory>> getCategories();
  Future<CountryPack> getCountryPack(String countryCode);
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

class IdMatchResult {
  const IdMatchResult({
    required this.outcome,
    this.matchedName,
    this.reasonKey,
  });

  final IdentityCheckOutcome outcome;
  final String? matchedName;
  final String? reasonKey;
}

/// Vendor-neutral identity-verification adapter. The Smile ID SDK (or
/// alternative picked by spike S-05) plugs in behind this; screens and
/// repositories never talk to a vendor SDK directly.
abstract interface class IdentityVerificationAdapter {
  Future<LivenessSession> startLivenessSession();
  Future<LivenessResult> captureLiveness(String sessionId);
  Future<IdMatchResult> matchGovernmentId(
    String sessionId,
    String idType,
    String idNumber,
  );
}

/// Customer facial-verification flow (phone OTP → consent → liveness + ID
/// lookup → result). All methods are action requests: the repository decides
/// outcomes and returns the new session state.
abstract interface class VerificationRepository {
  Future<VerificationSession?> getCustomerVerification();
  Stream<VerificationSession?> watchCustomerVerification();

  /// Records explicit consent for biometric processing (separate from
  /// criminal-record consent on the provider side).
  Future<VerificationSession> giveBiometricConsent();

  /// Throws AppError(ERR_CONSENT_REQUIRED) when consent was not given.
  Future<VerificationSession> startFacialVerification();

  /// Throws AppError(ERR_KYC_STEP_INVALID) when the session is not in a
  /// submittable state.
  Future<VerificationSession> submitIdLookup(
    String sessionId,
    String idType,
    String idNumber,
  );
}

/// Provider KYC: onboarding, per-step submission, payout-account name match
/// and final submission for Verification Officer review.
abstract interface class ProviderKycRepository {
  Future<ProviderKycProfile> getKycProfile();
  Stream<ProviderKycProfile> watchKycProfile();
  Future<ProviderKycProfile> saveOnboarding(ProviderOnboardingInput input);

  /// [input] is typed per [kind]: IdDocumentInput (governmentId,
  /// idDocumentCapture — capture requires uploadRef), String liveness
  /// sessionId (providerFacial), PoliceClearanceInput, AddressInput,
  /// GuarantorInput, PayoutAccountInput, VehicleDocumentsInput,
  /// CredentialsInput. Throws AppError(ERR_KYC_STEP_INVALID) on a wrong
  /// input type or an illegal state transition.
  Future<ProviderKycProfile> submitStep(KycStepKind kind, Object input);

  /// Server-style account-name lookup against the verified identity.
  /// Read-only: does not mutate the profile.
  Future<PayoutAccountResult> resolvePayoutAccount(PayoutAccountInput input);

  /// Throws AppError(ERR_KYC_INCOMPLETE) unless every required step is
  /// verified or in review (vehicle documents are required only for
  /// motorized vehicles).
  Future<ProviderKycProfile> submitForReview();
}
