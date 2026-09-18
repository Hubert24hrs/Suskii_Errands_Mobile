import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_data/suskii_data.dart';
import 'package:suskii_domain/suskii_domain.dart';

/// ---------------------------------------------------------------------------
/// Dependency injection. Screens depend ONLY on the repository interfaces from
/// suskii_domain; these providers bind them to the mock implementations.
/// At M9, the mock bindings get replaced by Supabase implementations —
/// screens do not change.
/// ---------------------------------------------------------------------------

final appConfigProvider = Provider<AppConfig>(
  (ref) => AppConfig.fromEnvironment(),
);

final loggerProvider = Provider<AppLogger>((ref) => const ConsoleAppLogger());

final mockBehaviorProvider = Provider<MockBehavior>((ref) => MockBehavior());

final mockDatabaseProvider = Provider<MockDatabase>((ref) => MockDatabase());

final bootstrapRepositoryProvider = Provider<BootstrapRepository>(
  (ref) => MockBootstrapRepository(
    ref.watch(mockDatabaseProvider),
    ref.watch(mockBehaviorProvider),
  ),
);

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => MockAuthRepository(
    ref.watch(mockDatabaseProvider),
    ref.watch(mockBehaviorProvider),
  ),
);

final userRepositoryProvider = Provider<UserRepository>(
  (ref) => MockUserRepository(
    ref.watch(mockDatabaseProvider),
    ref.watch(mockBehaviorProvider),
  ),
);

final requestRepositoryProvider = Provider<RequestRepository>(
  (ref) => MockRequestRepository(
    ref.watch(mockDatabaseProvider),
    ref.watch(mockBehaviorProvider),
  ),
);

final offerRepositoryProvider = Provider<OfferRepository>(
  (ref) => MockOfferRepository(
    ref.watch(mockDatabaseProvider),
    ref.watch(mockBehaviorProvider),
  ),
);

final providerRepositoryProvider = Provider<ProviderRepository>(
  (ref) => MockProviderRepository(
    ref.watch(mockDatabaseProvider),
    ref.watch(mockBehaviorProvider),
  ),
);

final jobProgressRepositoryProvider = Provider<JobProgressRepository>(
  (ref) => MockJobProgressRepository(
    ref.watch(mockDatabaseProvider),
    ref.watch(mockBehaviorProvider),
  ),
);

final trackingRepositoryProvider = Provider<TrackingRepository>(
  (ref) => MockTrackingRepository(
    ref.watch(mockDatabaseProvider),
    ref.watch(mockBehaviorProvider),
  ),
);

final chatRepositoryProvider = Provider<ChatRepository>(
  (ref) => MockChatRepository(
    ref.watch(mockDatabaseProvider),
    ref.watch(mockBehaviorProvider),
  ),
);

final walletRepositoryProvider = Provider<WalletRepository>(
  (ref) => MockWalletRepository(
    ref.watch(mockDatabaseProvider),
    ref.watch(mockBehaviorProvider),
  ),
);

final referralRepositoryProvider = Provider<ReferralRepository>(
  (ref) => MockReferralRepository(
    ref.watch(mockDatabaseProvider),
    ref.watch(mockBehaviorProvider),
  ),
);

final conciergeRepositoryProvider = Provider<ConciergeRepository>(
  (ref) => MockConciergeRepository(
    ref.watch(mockDatabaseProvider),
    ref.watch(mockBehaviorProvider),
  ),
);

final paymentRepositoryProvider = Provider<PaymentRepository>(
  (ref) => MockPaymentRepository(
    ref.watch(mockDatabaseProvider),
    ref.watch(mockBehaviorProvider),
  ),
);

final ratingRepositoryProvider = Provider<RatingRepository>(
  (ref) => MockRatingRepository(
    ref.watch(mockDatabaseProvider),
    ref.watch(mockBehaviorProvider),
  ),
);

final safetyRepositoryProvider = Provider<SafetyRepository>(
  (ref) => MockSafetyRepository(
    ref.watch(mockDatabaseProvider),
    ref.watch(mockBehaviorProvider),
  ),
);

/// Masked calls (LiveKit plugs in behind this interface at M9).
final callAdapterProvider = Provider<CallAdapter>(
  (ref) => MockCallAdapter(
    ref.watch(mockDatabaseProvider),
    ref.watch(mockBehaviorProvider),
  ),
);

final catalogRepositoryProvider = Provider<CatalogRepository>(
  (ref) => MockCatalogRepository(
    ref.watch(mockDatabaseProvider),
    ref.watch(mockBehaviorProvider),
  ),
);

final identityVerificationAdapterProvider =
    Provider<IdentityVerificationAdapter>(
      (ref) => MockIdentityVerificationAdapter(
        ref.watch(mockDatabaseProvider),
        ref.watch(mockBehaviorProvider),
      ),
    );

final verificationRepositoryProvider = Provider<VerificationRepository>(
  (ref) => MockVerificationRepository(
    ref.watch(mockDatabaseProvider),
    ref.watch(mockBehaviorProvider),
  ),
);

final providerKycRepositoryProvider = Provider<ProviderKycRepository>(
  (ref) => MockProviderKycRepository(
    ref.watch(mockDatabaseProvider),
    ref.watch(mockBehaviorProvider),
  ),
);

/// ---------------------------------------------------------------------------
/// Session / app state
/// ---------------------------------------------------------------------------

final authStateProvider = StreamProvider<AuthState>(
  (ref) => ref.watch(authRepositoryProvider).authStateChanges(),
);

final bootstrapProvider = FutureProvider<AppBootstrap>(
  (ref) => ref.watch(bootstrapRepositoryProvider).getBootstrap(),
);

/// Customer/Provider mode. Default Customer; Provider requires verification
/// (enforced server-side later, enforced by the repository contract now).
class ModeController extends Notifier<UserMode> {
  bool _seeded = false;

  @override
  UserMode build() => UserMode.customer;

  void seed(UserMode mode) {
    if (_seeded) return;
    _seeded = true;
    state = mode;
  }

  /// Throws AppError (e.g. ERR_PROVIDER_NOT_VERIFIED) — callers localize.
  Future<void> switchMode(UserMode target) async {
    final mode = await ref
        .read(userRepositoryProvider)
        .setActiveMode(target, idempotencyKey: newIdempotencyKey());
    state = mode;
  }
}

final modeControllerProvider = NotifierProvider<ModeController, UserMode>(
  ModeController.new,
);

/// Mock-driven connectivity. Toggling also flips the mock layer's offline
/// switch so every screen's offline state is demoable.
class ConnectivityController extends Notifier<ConnectivityStatus> {
  @override
  ConnectivityStatus build() => ConnectivityStatus.online;

  void toggleSimulatedOffline() {
    state = state == ConnectivityStatus.online
        ? ConnectivityStatus.offline
        : ConnectivityStatus.online;
    ref.read(mockBehaviorProvider).offline =
        state == ConnectivityStatus.offline;
  }
}

final connectivityProvider =
    NotifierProvider<ConnectivityController, ConnectivityStatus>(
      ConnectivityController.new,
    );

/// null = follow system / country default.
class LocaleController extends Notifier<Locale?> {
  @override
  Locale? build() => null;

  void setLocale(Locale? locale) => state = locale;
}

final localeControllerProvider = NotifierProvider<LocaleController, Locale?>(
  LocaleController.new,
);

class ThemeModeController extends Notifier<ThemeMode> {
  @override
  ThemeMode build() => ThemeMode.system;

  void setThemeMode(ThemeMode mode) => state = mode;
}

final themeModeControllerProvider =
    NotifierProvider<ThemeModeController, ThemeMode>(ThemeModeController.new);

/// ---------------------------------------------------------------------------
/// Screen-level data providers (M1 home/shell surfaces)
/// ---------------------------------------------------------------------------

final activeJobsProvider = FutureProvider<List<JobRequest>>(
  (ref) => ref.watch(requestRepositoryProvider).getMyActiveJobs(),
);

final categoriesProvider = FutureProvider<List<ServiceCategory>>(
  (ref) => ref.watch(catalogRepositoryProvider).getCategories(),
);

final providerHomeProvider = FutureProvider<ProviderHomeSummary>(
  (ref) => ref.watch(providerRepositoryProvider).getHomeSummary(),
);

final nearbyRequestsProvider = StreamProvider<List<JobRequest>>(
  (ref) => ref.watch(providerRepositoryProvider).watchNearbyRequests(),
);

final walletSummaryProvider = FutureProvider<WalletSummary>(
  (ref) => ref.watch(walletRepositoryProvider).getSummary(),
);

final walletTransactionsProvider = FutureProvider<List<WalletTransaction>>(
  (ref) => ref.watch(walletRepositoryProvider).getTransactions(),
);

final voiceConciergeAdapterProvider = Provider<VoiceConciergeAdapter>(
  (ref) => MockVoiceConciergeAdapter(
    ref.watch(mockDatabaseProvider),
    ref.watch(mockBehaviorProvider),
  ),
);

/// Server-time clock, synced from bootstrap `serverTime`. Every countdown
/// (offer TTL, request expiry) renders against this, never raw device time.
final serverClockProvider = Provider<ServerClock>((ref) {
  final clock = ServerClock();
  final boot = ref.watch(bootstrapProvider).value;
  if (boot != null) clock.sync(boot.serverTime);
  return clock;
});

/// ---------------------------------------------------------------------------
/// Screen-level data providers (M3: requests, concierge, offers)
/// ---------------------------------------------------------------------------

final requestDetailProvider = StreamProvider.family<JobRequest, String>(
  (ref, jobId) => ref.watch(requestRepositoryProvider).watchJob(jobId),
);

final offersProvider = StreamProvider.family<List<Offer>, String>(
  (ref, requestId) => ref.watch(offerRepositoryProvider).watchOffers(requestId),
);

/// Advisory price band per category — a hint next to the preferred-price
/// field, never used to set a price.
final priceBandProvider = FutureProvider.family<PriceBand, String>(
  (ref, categoryId) =>
      ref.watch(catalogRepositoryProvider).getPriceBand(categoryId: categoryId),
);

/// ---------------------------------------------------------------------------
/// Screen-level data providers (M4: payments, tracking, chat, safety, ratings)
/// ---------------------------------------------------------------------------

final paymentForJobProvider = StreamProvider.family<Payment?, String>(
  (ref, jobId) =>
      ref.watch(paymentRepositoryProvider).watchPaymentForJob(jobId),
);

final chatMessagesProvider = StreamProvider.family<List<ChatMessage>, String>(
  (ref, jobId) => ref.watch(chatRepositoryProvider).watchMessages(jobId),
);

final providerLocationProvider = StreamProvider.family<GeoPoint, String>(
  (ref, jobId) =>
      ref.watch(trackingRepositoryProvider).watchProviderLocation(jobId),
);

final activeSosProvider = StreamProvider.family<SosAlert?, String>(
  (ref, jobId) => ref.watch(safetyRepositoryProvider).watchActiveSos(jobId),
);

final myRatingProvider = FutureProvider.family<Rating?, String>(
  (ref, jobId) => ref.watch(ratingRepositoryProvider).getMyRatingForJob(jobId),
);
