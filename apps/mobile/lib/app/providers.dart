import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;
import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_data/suskii_data.dart';
import 'package:suskii_domain/suskii_domain.dart';

/// ---------------------------------------------------------------------------
/// Dependency injection. Screens depend ONLY on the repository interfaces from
/// suskii_domain. When the flavor carries Supabase credentials (M9), providers
/// bind to the Supabase implementations module by module; everything not yet
/// wired stays on the mock implementations — screens do not change.
/// ---------------------------------------------------------------------------

final appConfigProvider = Provider<AppConfig>(
  (ref) => AppConfig.fromEnvironment(),
);

final loggerProvider = Provider<AppLogger>((ref) => const ConsoleAppLogger());

/// The Supabase gateway, or null when the flavor has no project credentials
/// (the default until a project is provisioned) — the app then runs on mocks.
/// `Supabase.instance` is initialized in `main.dart` under the same condition,
/// so it is safe to reach here only when configured.
final supabaseGatewayProvider = Provider<SupabaseGateway?>((ref) {
  final config = ref.watch(appConfigProvider);
  if (config.supabaseUrl.isEmpty || config.supabaseAnonKey.isEmpty) {
    return null;
  }
  return SupabaseGateway(Supabase.instance.client);
});

final mockBehaviorProvider = Provider<MockBehavior>((ref) => MockBehavior());

final mockDatabaseProvider = Provider<MockDatabase>((ref) => MockDatabase());

final bootstrapRepositoryProvider = Provider<BootstrapRepository>((ref) {
  final gateway = ref.watch(supabaseGatewayProvider);
  if (gateway != null) return SupabaseBootstrapRepository(gateway);
  return MockBootstrapRepository(
    ref.watch(mockDatabaseProvider),
    ref.watch(mockBehaviorProvider),
  );
});

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  final gateway = ref.watch(supabaseGatewayProvider);
  if (gateway != null) return SupabaseAuthRepository(gateway);
  return MockAuthRepository(
    ref.watch(mockDatabaseProvider),
    ref.watch(mockBehaviorProvider),
  );
});

final userRepositoryProvider = Provider<UserRepository>(
  (ref) => MockUserRepository(
    ref.watch(mockDatabaseProvider),
    ref.watch(mockBehaviorProvider),
  ),
);

final requestRepositoryProvider = Provider<RequestRepository>((ref) {
  final gateway = ref.watch(supabaseGatewayProvider);
  if (gateway != null) return SupabaseRequestRepository(gateway);
  return MockRequestRepository(
    ref.watch(mockDatabaseProvider),
    ref.watch(mockBehaviorProvider),
  );
});

final offerRepositoryProvider = Provider<OfferRepository>((ref) {
  final gateway = ref.watch(supabaseGatewayProvider);
  if (gateway != null) return SupabaseOfferRepository(gateway);
  return MockOfferRepository(
    ref.watch(mockDatabaseProvider),
    ref.watch(mockBehaviorProvider),
  );
});

final providerRepositoryProvider = Provider<ProviderRepository>((ref) {
  final gateway = ref.watch(supabaseGatewayProvider);
  if (gateway != null) return SupabaseProviderRepository(gateway);
  return MockProviderRepository(
    ref.watch(mockDatabaseProvider),
    ref.watch(mockBehaviorProvider),
  );
});

final jobProgressRepositoryProvider = Provider<JobProgressRepository>((ref) {
  final gateway = ref.watch(supabaseGatewayProvider);
  if (gateway != null) return SupabaseJobProgressRepository(gateway);
  return MockJobProgressRepository(
    ref.watch(mockDatabaseProvider),
    ref.watch(mockBehaviorProvider),
  );
});

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

final walletRepositoryProvider = Provider<WalletRepository>((ref) {
  final gateway = ref.watch(supabaseGatewayProvider);
  if (gateway != null) return SupabaseWalletRepository(gateway);
  return MockWalletRepository(
    ref.watch(mockDatabaseProvider),
    ref.watch(mockBehaviorProvider),
  );
});

final referralRepositoryProvider = Provider<ReferralRepository>((ref) {
  final gateway = ref.watch(supabaseGatewayProvider);
  if (gateway != null) return SupabaseReferralRepository(gateway);
  return MockReferralRepository(
    ref.watch(mockDatabaseProvider),
    ref.watch(mockBehaviorProvider),
  );
});

final conciergeRepositoryProvider = Provider<ConciergeRepository>(
  (ref) => MockConciergeRepository(
    ref.watch(mockDatabaseProvider),
    ref.watch(mockBehaviorProvider),
  ),
);

final paymentRepositoryProvider = Provider<PaymentRepository>((ref) {
  final gateway = ref.watch(supabaseGatewayProvider);
  if (gateway != null) return SupabasePaymentRepository(gateway);
  return MockPaymentRepository(
    ref.watch(mockDatabaseProvider),
    ref.watch(mockBehaviorProvider),
  );
});

final ratingRepositoryProvider = Provider<RatingRepository>((ref) {
  final gateway = ref.watch(supabaseGatewayProvider);
  if (gateway != null) return SupabaseRatingRepository(gateway);
  return MockRatingRepository(
    ref.watch(mockDatabaseProvider),
    ref.watch(mockBehaviorProvider),
  );
});

final safetyRepositoryProvider = Provider<SafetyRepository>((ref) {
  final gateway = ref.watch(supabaseGatewayProvider);
  if (gateway != null) return SupabaseSafetyRepository(gateway);
  return MockSafetyRepository(
    ref.watch(mockDatabaseProvider),
    ref.watch(mockBehaviorProvider),
  );
});

/// Masked calls (LiveKit plugs in behind this interface at M9).
final callAdapterProvider = Provider<CallAdapter>(
  (ref) => MockCallAdapter(
    ref.watch(mockDatabaseProvider),
    ref.watch(mockBehaviorProvider),
  ),
);

final catalogRepositoryProvider = Provider<CatalogRepository>((ref) {
  final gateway = ref.watch(supabaseGatewayProvider);
  if (gateway != null) return SupabaseCatalogRepository(gateway);
  return MockCatalogRepository(
    ref.watch(mockDatabaseProvider),
    ref.watch(mockBehaviorProvider),
  );
});

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

/// The signed-in provider's own offers across all requests (M8.6).
final myOffersProvider = FutureProvider<List<Offer>>(
  (ref) => ref.watch(providerRepositoryProvider).getMyOffers(),
);

/// Active jobs assigned to the signed-in provider (M8.6).
final providerJobsProvider = StreamProvider<List<JobRequest>>(
  (ref) => ref.watch(providerRepositoryProvider).watchMyJobs(),
);

/// Terminal jobs of the signed-in provider, first page (M8.6).
final providerJobsHistoryProvider = FutureProvider<List<JobRequest>>(
  (ref) => ref.watch(providerRepositoryProvider).getMyJobsHistory(),
);

/// Proofs attached to a job (M8.6 job execution).
final jobProofsProvider = FutureProvider.family<List<Proof>, String>(
  (ref, jobId) => ref.watch(jobProgressRepositoryProvider).getProofs(jobId),
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
/// field, never used to set a price. Keyed by (category, urgency); a null
/// band means the server has no basis at all — show no hint.
final priceBandProvider = FutureProvider.family<PriceBand?, (String, Urgency)>((
  ref,
  key,
) {
  return ref
      .watch(catalogRepositoryProvider)
      .getPriceBand(categoryId: key.$1, urgency: key.$2);
});

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

/// ---------------------------------------------------------------------------
/// M5: disputes, support, promos, settings
/// ---------------------------------------------------------------------------

final disputeRepositoryProvider = Provider<DisputeRepository>((ref) {
  final gateway = ref.watch(supabaseGatewayProvider);
  if (gateway != null) return SupabaseDisputeRepository(gateway);
  return MockDisputeRepository(
    ref.watch(mockDatabaseProvider),
    ref.watch(mockBehaviorProvider),
  );
});

final supportRepositoryProvider = Provider<SupportRepository>(
  (ref) => MockSupportRepository(
    ref.watch(mockDatabaseProvider),
    ref.watch(mockBehaviorProvider),
  ),
);

final promoRepositoryProvider = Provider<PromoRepository>(
  (ref) => MockPromoRepository(
    ref.watch(mockDatabaseProvider),
    ref.watch(mockBehaviorProvider),
  ),
);

final settingsRepositoryProvider = Provider<SettingsRepository>(
  (ref) => MockSettingsRepository(
    ref.watch(mockDatabaseProvider),
    ref.watch(mockBehaviorProvider),
  ),
);

final myDisputesProvider = FutureProvider<List<Dispute>>(
  (ref) => ref.watch(disputeRepositoryProvider).getMyDisputes(),
);

final disputeForJobProvider = StreamProvider.family<Dispute?, String>(
  (ref, jobId) => ref.watch(disputeRepositoryProvider).watchDispute(jobId),
);

final supportTicketsProvider = StreamProvider<List<SupportTicket>>(
  (ref) => ref.watch(supportRepositoryProvider).watchTickets(),
);

final promosProvider = FutureProvider<List<Promo>>(
  (ref) => ref.watch(promoRepositoryProvider).getPromos(),
);

final referralSummaryProvider = FutureProvider<ReferralSummary>(
  (ref) => ref.watch(referralRepositoryProvider).getSummary(),
);

final notificationPrefsProvider = FutureProvider<NotificationPreferences>(
  (ref) => ref.watch(settingsRepositoryProvider).getNotificationPreferences(),
);

final trustedContactsProvider = FutureProvider<List<TrustedContact>>(
  (ref) => ref.watch(settingsRepositoryProvider).getTrustedContacts(),
);

/// ---------------------------------------------------------------------------
/// M6: provider tools + business console
/// ---------------------------------------------------------------------------

final providerToolsRepositoryProvider = Provider<ProviderToolsRepository>(
  (ref) => MockProviderToolsRepository(
    ref.watch(mockDatabaseProvider),
    ref.watch(mockBehaviorProvider),
  ),
);

final organizationRepositoryProvider = Provider<OrganizationRepository>(
  (ref) => MockOrganizationRepository(
    ref.watch(mockDatabaseProvider),
    ref.watch(mockBehaviorProvider),
  ),
);

final availabilityProvider = FutureProvider<List<AvailabilitySlot>>(
  (ref) => ref.watch(providerToolsRepositoryProvider).getAvailability(),
);

final earningsGoalProvider = FutureProvider<EarningsGoal?>(
  (ref) => ref.watch(providerToolsRepositoryProvider).getEarningsGoal(),
);

final demandHeatmapProvider = FutureProvider<List<DemandZone>>(
  (ref) => ref.watch(providerToolsRepositoryProvider).getDemandHeatmap(),
);

final providerInsightsProvider = FutureProvider<ProviderInsights>(
  (ref) => ref.watch(providerToolsRepositoryProvider).getInsights(),
);

final myOrganizationProvider = FutureProvider<Organization?>(
  (ref) => ref.watch(organizationRepositoryProvider).getMyOrganization(),
);

final orgMembersProvider = FutureProvider<List<OrgMember>>(
  (ref) => ref.watch(organizationRepositoryProvider).getMembers(),
);

final orgVehiclesProvider = FutureProvider<List<Vehicle>>(
  (ref) => ref.watch(organizationRepositoryProvider).getVehicles(),
);

final orgAssignableJobsProvider = FutureProvider<List<JobRequest>>(
  (ref) => ref.watch(organizationRepositoryProvider).getAssignableJobs(),
);
