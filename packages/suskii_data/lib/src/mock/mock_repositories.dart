import 'dart:async';

import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_domain/suskii_domain.dart';

import 'fixtures.dart';
import 'mock_behavior.dart';
import 'server_sim.dart';

/// Base class wiring the shared behavior gate (latency/offline/failure).
abstract class _MockRepo {
  _MockRepo(this.db, this.behavior);

  final MockDatabase db;
  final MockBehavior behavior;

  Future<void> gate() => behavior.gate();

  AppUser get currentUser {
    final user = db.users[behavior.currentUserId];
    if (user == null) throw const AppError(ErrorCodes.unauthenticated);
    return user;
  }
}

class MockBootstrapRepository extends _MockRepo implements BootstrapRepository {
  MockBootstrapRepository(super.db, super.behavior);

  @override
  Future<AppBootstrap> getBootstrap() async {
    await gate();
    final user = db.users[behavior.currentUserId];
    final pack =
        db.countryPacks[user?.countryCode ?? 'NG'] ?? db.countryPacks['NG']!;
    if (pack.status == CountryStatus.disabled) {
      throw const AppError(ErrorCodes.countryDisabled);
    }
    final activeJob = db.requests.values
        .where(
          (JobRequest r) =>
              (r.customerId == user?.id || r.providerId == user?.id) &&
              r.status.needsAttention,
        )
        .firstOrNull;
    return AppBootstrap(
      user: user,
      countryPack: pack,
      featureFlags: const <String, bool>{
        'aiConcierge': true,
        'voiceConcierge': true,
        'inAppCalls': true,
        'referrals': true,
        'scheduledErrands': true,
      },
      minSupportedAppVersion: '0.1.0',
      unreadNotifications: db.notifications
          .where((AppNotification n) => !n.read)
          .length,
      activeJobBanner: activeJob == null
          ? null
          : ActiveJobBanner(
              jobId: activeJob.id,
              status: activeJob.status,
              otherPartyName: activeJob.providerId == null
                  ? 'Suskii'
                  : db.providers[activeJob.providerId]?.displayName ??
                        'Provider',
              categoryLabelKey: db.categories
                  .firstWhere(
                    (ServiceCategory c) => c.id == activeJob.categoryId,
                    orElse: () => db.categories.last,
                  )
                  .labelKey,
              agreedPrice: activeJob.agreedPrice,
            ),
    );
  }

  @override
  Stream<AppNotification> watchNotifications() => db.notificationEvents.stream;
}

class MockAuthRepository extends _MockRepo implements AuthRepository {
  MockAuthRepository(super.db, super.behavior);

  final StreamController<AuthState> _controller =
      StreamController<AuthState>.broadcast();
  AuthState _state = const AuthState(status: AuthStatus.signedOut);

  @override
  Stream<AuthState> authStateChanges() async* {
    yield _state;
    yield* _controller.stream;
  }

  @override
  Future<void> requestPhoneOtp(String phoneE164) => gate();

  @override
  Future<AppUser> verifyPhoneOtp(String phoneE164, String code) async {
    await gate();
    if (code.length != 6) {
      throw const AppError(ErrorCodes.otpInvalid);
    }
    final user = db.users[behavior.currentUserId]!;
    _state = AuthState(status: AuthStatus.signedIn, user: user);
    _controller.add(_state);
    return user;
  }

  @override
  Future<void> requestEmailOtp(String email) => gate();

  @override
  Future<AppUser> verifyEmailOtp(String email, String code) async {
    await gate();
    if (code.length != 6) {
      throw const AppError(ErrorCodes.otpInvalid);
    }
    final user = db.users[behavior.currentUserId]!;
    final updated = user.copyWith(email: user.email ?? email);
    db.users[user.id] = updated;
    _state = AuthState(status: AuthStatus.signedIn, user: updated);
    _controller.add(_state);
    return updated;
  }

  @override
  Future<AppUser> signInWithGoogle() async {
    await gate();
    throw const AppError(ErrorCodes.featureUnavailable);
  }

  @override
  Future<AppUser> signInWithApple() async {
    await gate();
    throw const AppError(ErrorCodes.featureUnavailable);
  }

  @override
  Future<void> signOut() async {
    await gate();
    _state = const AuthState(status: AuthStatus.signedOut);
    _controller.add(_state);
  }
}

class MockUserRepository extends _MockRepo implements UserRepository {
  MockUserRepository(super.db, super.behavior);

  final StreamController<AppUser> _controller =
      StreamController<AppUser>.broadcast();

  @override
  Future<AppUser> getProfile() async {
    await gate();
    return currentUser;
  }

  @override
  Stream<AppUser> watchProfile() async* {
    yield currentUser;
    yield* _controller.stream;
  }

  @override
  Future<UserMode> setActiveMode(UserMode mode) async {
    await gate();
    final user = currentUser;
    if (mode == UserMode.provider &&
        user.providerVerification != VerificationStatus.verified) {
      throw const AppError(ErrorCodes.providerNotVerified);
    }
    final updated = user.copyWith(activeMode: mode);
    db.users[user.id] = updated;
    _controller.add(updated);
    return mode;
  }
}

class MockRequestRepository extends _MockRepo implements RequestRepository {
  MockRequestRepository(super.db, super.behavior);

  @override
  Future<List<JobRequest>> getMyActiveJobs() async {
    await gate();
    return db.requests.values
        .where(
          (JobRequest r) =>
              r.customerId == currentUser.id && !r.status.isTerminal,
        )
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  @override
  Future<List<JobRequest>> getMyRequestHistory({
    String? cursor,
    int limit = 20,
  }) async {
    await gate();
    final history =
        db.requests.values
            .where(
              (JobRequest r) =>
                  r.customerId == currentUser.id && r.status.isTerminal,
            )
            .toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final start = cursor == null
        ? 0
        : history.indexWhere((JobRequest r) => r.id == cursor) + 1;
    return history.skip(start).take(limit).toList();
  }

  @override
  Stream<JobRequest> watchJob(String jobId) async* {
    final current = db.requests[jobId];
    if (current != null) yield current;
    yield* db.jobEvents.stream.where((JobRequest r) => r.id == jobId);
  }

  @override
  Future<JobRequest> createRequest(CreateRequestInput input) async {
    await gate();
    final user = currentUser;
    if (user.customerVerification != VerificationStatus.verified) {
      throw const AppError(ErrorCodes.permissionDenied);
    }
    final id = 'req-${DateTime.now().millisecondsSinceEpoch}';
    final request = JobRequest(
      id: id,
      customerId: user.id,
      categoryId: input.categoryId,
      isCustomCategory: input.isCustomCategory,
      description: input.description,
      mediaPaths: input.mediaPaths,
      pickup: input.pickup,
      destination: input.destination,
      urgency: input.urgency,
      status: JobStatus.published,
      createdAt: DateTime.now(),
      scheduledAt: input.scheduledAt,
      preferredPrice: input.preferredPrice,
      itemFloat: input.itemFloat,
      declaredValue: input.declaredValue,
      expiresAt: DateTime.now().add(const Duration(hours: 4)),
    );
    db.requests[id] = request;
    db.jobEvents.add(request);
    return request;
  }

  @override
  Future<JobRequest> cancelRequest(String jobId, String reasonKey) async {
    await gate();
    final request = db.requests[jobId];
    if (request == null) throw const AppError(ErrorCodes.unknown);
    const cancellable = <JobStatus>{
      JobStatus.draft,
      JobStatus.published,
      JobStatus.offersReceived,
      JobStatus.negotiating,
      JobStatus.agreed,
      JobStatus.paymentPending,
    };
    if (!cancellable.contains(request.status)) {
      throw const AppError(ErrorCodes.jobNotCancellable);
    }
    final updated = request.copyWith(status: JobStatus.cancelled);
    db.requests[jobId] = updated;
    db.jobEvents.add(updated);
    return updated;
  }
}

class MockOfferRepository extends _MockRepo implements OfferRepository {
  MockOfferRepository(super.db, super.behavior);

  Timer? _demoTimer;

  @override
  Stream<List<Offer>> watchOffers(String requestId) {
    late StreamController<List<Offer>> controller;
    controller = StreamController<List<Offer>>(
      onListen: () {
        controller.add(List<Offer>.unmodifiable(db.offers[requestId] ?? []));
        final request = db.requests[requestId];
        // Simulated realtime: a fresh offer lands shortly after opening the
        // board while the request is still collecting offers.
        if (request != null &&
            (request.status == JobStatus.published ||
                request.status == JobStatus.negotiating ||
                request.status == JobStatus.offersReceived)) {
          _demoTimer = Timer(const Duration(seconds: 8), () {
            final newOffer = Offer(
              id: 'offer-live-${DateTime.now().millisecondsSinceEpoch}',
              requestId: requestId,
              providerId: 'provider-ngozi',
              providerName: 'Ngozi Adeyemi',
              providerRating: 4.9,
              providerTrustLevel: TrustLevel.elite,
              amount: const Money(550000, 'NGN'),
              status: OfferStatus.pending,
              round: 1,
              createdAt: DateTime.now(),
              message: 'I can start immediately.',
              distanceMeters: 1500,
              payoutEstimate: simulateQuote(
                const Money(550000, 'NGN'),
                estimatedGatewayFee: const Money(8250, 'NGN'),
              ),
              expiresAt: DateTime.now().add(const Duration(minutes: 10)),
            );
            db.offers.putIfAbsent(requestId, () => <Offer>[]).add(newOffer);
            db.offerEvents.add(newOffer);
            controller.add(
              List<Offer>.unmodifiable(db.offers[requestId] ?? []),
            );
          });
        }
      },
      onCancel: () {
        _demoTimer?.cancel();
        unawaited(controller.close());
      },
    );
    return controller.stream;
  }

  @override
  Future<Offer> acceptOffer(String offerId) async {
    await gate();
    final (requestId, index, offer) = _find(offerId);
    if (offer.status == OfferStatus.expired ||
        (offer.expiresAt != null &&
            offer.expiresAt!.isBefore(DateTime.now()))) {
      throw const AppError(ErrorCodes.offerExpired);
    }
    final list = db.offers[requestId]!;
    final accepted = offer.copyWith(status: OfferStatus.accepted);
    list[index] = accepted;
    for (var i = 0; i < list.length; i++) {
      if (i != index && list[i].status == OfferStatus.pending) {
        list[i] = list[i].copyWith(status: OfferStatus.expired);
      }
    }
    final request = db.requests[requestId]!;
    final updated = request.copyWith(
      status: JobStatus.agreed,
      agreedPrice: accepted.amount,
      agreedBreakdown: simulateQuote(accepted.amount),
      providerId: accepted.providerId,
    );
    db.requests[requestId] = updated;
    db.jobEvents.add(updated);
    db.offerEvents.add(accepted);
    return accepted;
  }

  @override
  Future<Offer> declineOffer(String offerId) async {
    await gate();
    final (requestId, index, offer) = _find(offerId);
    final declined = offer.copyWith(status: OfferStatus.declined);
    db.offers[requestId]![index] = declined;
    db.offerEvents.add(declined);
    return declined;
  }

  @override
  Future<Offer> counterOffer({
    required String offerId,
    required Money amount,
    String? message,
  }) async {
    await gate();
    final (requestId, index, offer) = _find(offerId);
    final pack = db.countryPacks[currentUser.countryCode]!;
    if (offer.round >= pack.maxNegotiationRounds) {
      throw const AppError(ErrorCodes.offerRoundsExhausted);
    }
    if (offer.status == OfferStatus.expired) {
      throw const AppError(ErrorCodes.offerExpired);
    }
    final countered = offer.copyWith(
      status: OfferStatus.countered,
      amount: amount,
      message: message,
      round: offer.round + 1,
      expiresAt: DateTime.now().add(Duration(seconds: pack.offerTtlSeconds)),
    );
    db.offers[requestId]![index] = countered;
    db.offerEvents.add(countered);
    return countered;
  }

  (String, int, Offer) _find(String offerId) {
    for (final entry in db.offers.entries) {
      final index = entry.value.indexWhere((Offer o) => o.id == offerId);
      if (index >= 0) return (entry.key, index, entry.value[index]);
    }
    throw const AppError(ErrorCodes.unknown);
  }
}

class MockProviderRepository extends _MockRepo implements ProviderRepository {
  MockProviderRepository(super.db, super.behavior);

  bool _online = false;

  @override
  Future<ProviderHomeSummary> getHomeSummary() async {
    await gate();
    final user = currentUser;
    return ProviderHomeSummary(
      online: _online,
      verificationStatus: user.providerVerification,
      todayEarnings: const Money(1260000, 'NGN'),
      completedToday: 3,
      nearbyOpenRequests: db.requests.values
          .where((JobRequest r) => r.status == JobStatus.published)
          .length,
      documentWarnings: const <DocumentExpiryWarning>[
        DocumentExpiryWarning(
          documentTypeKey: 'docPoliceClearance',
          daysRemaining: 14,
        ),
      ],
    );
  }

  @override
  Stream<List<JobRequest>> watchNearbyRequests() {
    late StreamController<List<JobRequest>> controller;
    Timer? timer;
    controller = StreamController<List<JobRequest>>(
      onListen: () {
        List<JobRequest> snapshot() => db.requests.values
            .where((JobRequest r) => r.status == JobStatus.published)
            .toList();
        controller.add(snapshot());
        // Simulated realtime: a new nearby request appears periodically.
        timer = Timer.periodic(const Duration(seconds: 25), (_) {
          final id = 'req-live-${DateTime.now().millisecondsSinceEpoch}';
          final request = JobRequest(
            id: id,
            customerId: 'user-chidi',
            categoryId: 'errands_delivery',
            isCustomCategory: false,
            description: 'Pick up a cake from a bakery in VI.',
            mediaPaths: const <String>[],
            pickup: const PlaceRef(
              label: 'Bakery, Victoria Island',
              point: GeoPoint(latitude: 6.4281, longitude: 3.4219),
            ),
            urgency: Urgency.standard,
            status: JobStatus.published,
            createdAt: DateTime.now(),
            preferredPrice: const Money(300000, 'NGN'),
          );
          db.requests[id] = request;
          db.jobEvents.add(request);
          controller.add(snapshot());
        });
      },
      onCancel: () {
        timer?.cancel();
        unawaited(controller.close());
      },
    );
    return controller.stream;
  }

  @override
  Future<List<Offer>> getMyOffers() async {
    await gate();
    return db.offers.values
        .expand((List<Offer> l) => l)
        .where((Offer o) => o.providerId == currentUser.id)
        .toList();
  }

  @override
  Future<Offer> submitOffer({
    required String requestId,
    required Money amount,
    String? message,
  }) async {
    await gate();
    final request = db.requests[requestId];
    if (request == null) throw const AppError(ErrorCodes.unknown);
    if (request.customerId == currentUser.id) {
      throw const AppError(ErrorCodes.selfDealingBlocked);
    }
    final user = currentUser;
    final offer = Offer(
      id: 'offer-${DateTime.now().millisecondsSinceEpoch}',
      requestId: requestId,
      providerId: user.id,
      providerName: user.displayName,
      providerRating: 4.5,
      providerTrustLevel: user.trustLevel,
      amount: amount,
      status: OfferStatus.pending,
      round: 1,
      createdAt: DateTime.now(),
      message: message,
      payoutEstimate: simulateQuote(amount),
      expiresAt: DateTime.now().add(const Duration(minutes: 10)),
    );
    db.offers.putIfAbsent(requestId, () => <Offer>[]).add(offer);
    db.offerEvents.add(offer);
    return offer;
  }

  @override
  Future<bool> setOnline(bool online) async {
    await gate();
    final user = currentUser;
    if (online) {
      if (user.providerVerification != VerificationStatus.verified) {
        throw const AppError(ErrorCodes.providerNotVerified);
      }
      if (db.providerBusyRuleEnabled) {
        final busy = db.requests.values.any(
          (JobRequest r) =>
              r.customerId == user.id &&
              (r.status == JobStatus.paymentPending ||
                  r.status == JobStatus.disputed),
        );
        if (busy) throw const AppError(ErrorCodes.providerBusyAsCustomer);
      }
    }
    _online = online;
    return online;
  }
}

class MockJobProgressRepository extends _MockRepo
    implements JobProgressRepository {
  MockJobProgressRepository(super.db, super.behavior);

  static const Map<JobStatus, Set<JobStatus>> _allowed =
      <JobStatus, Set<JobStatus>>{
        JobStatus.assigned: <JobStatus>{JobStatus.enRoute},
        JobStatus.enRoute: <JobStatus>{JobStatus.arrived},
        JobStatus.arrived: <JobStatus>{JobStatus.inProgress},
        JobStatus.inProgress: <JobStatus>{JobStatus.completedByProvider},
      };

  @override
  Future<JobRequest> requestStatusChange(String jobId, JobStatus target) async {
    await gate();
    final request = db.requests[jobId];
    if (request == null) throw const AppError(ErrorCodes.unknown);
    final allowedTargets = _allowed[request.status] ?? const <JobStatus>{};
    if (!allowedTargets.contains(target)) {
      throw const AppError(ErrorCodes.permissionDenied);
    }
    final updated = request.copyWith(status: target);
    db.requests[jobId] = updated;
    db.jobEvents.add(updated);
    return updated;
  }

  @override
  Future<JobRequest> confirmCompletion(String jobId) async {
    await gate();
    final request = db.requests[jobId];
    if (request == null) throw const AppError(ErrorCodes.unknown);
    if (request.status != JobStatus.completedByProvider) {
      throw const AppError(ErrorCodes.permissionDenied);
    }
    final updated = request.copyWith(status: JobStatus.confirmed);
    db.requests[jobId] = updated;
    db.jobEvents.add(updated);
    return updated;
  }

  @override
  Future<bool> verifyHandoverPin(String jobId, String pin) async {
    await gate();
    return pin == '4281';
  }
}

class MockTrackingRepository extends _MockRepo implements TrackingRepository {
  MockTrackingRepository(super.db, super.behavior);

  static const _start = GeoPoint(latitude: 6.4281, longitude: 3.4219);
  static const _end = GeoPoint(latitude: 6.4311, longitude: 3.4359);

  @override
  Stream<GeoPoint> watchProviderLocation(String jobId) {
    var step = 0;
    const totalSteps = 30;
    return Stream<GeoPoint>.periodic(const Duration(seconds: 2), (_) {
      step = (step + 1).clamp(0, totalSteps);
      final t = step / totalSteps;
      return GeoPoint(
        latitude: _start.latitude + (_end.latitude - _start.latitude) * t,
        longitude: _start.longitude + (_end.longitude - _start.longitude) * t,
      );
    });
  }
}

class MockChatRepository extends _MockRepo implements ChatRepository {
  MockChatRepository(super.db, super.behavior);

  final Map<String, StreamController<List<ChatMessage>>> _controllers =
      <String, StreamController<List<ChatMessage>>>{};

  @override
  Stream<List<ChatMessage>> watchMessages(String jobId) {
    final controller = _controllers.putIfAbsent(
      jobId,
      StreamController<List<ChatMessage>>.broadcast,
    );
    unawaited(
      Future<void>.microtask(
        () => controller.add(List.unmodifiable(db.chats[jobId] ?? const [])),
      ),
    );
    return controller.stream;
  }

  @override
  Future<ChatMessage> sendMessage({
    required String jobId,
    required ChatMessageType type,
    String? text,
    String? mediaPath,
    GeoPoint? location,
  }) async {
    await gate();
    final message = ChatMessage(
      id: 'msg-${DateTime.now().millisecondsSinceEpoch}',
      jobId: jobId,
      senderId: currentUser.id,
      type: type,
      text: text,
      mediaPath: mediaPath,
      location: location,
      createdAt: DateTime.now(),
    );
    db.chats.putIfAbsent(jobId, () => <ChatMessage>[]).add(message);
    final controller = _controllers[jobId];
    if (controller != null) {
      controller.add(List.unmodifiable(db.chats[jobId]!));
    }
    return message;
  }
}

class MockWalletRepository extends _MockRepo implements WalletRepository {
  MockWalletRepository(super.db, super.behavior);

  @override
  Future<WalletSummary> getSummary() async {
    await gate();
    return db.wallets[currentUser.id] ??
        WalletSummary(
          available: Money(0, _currency()),
          pending: Money(0, _currency()),
        );
  }

  @override
  Future<List<WalletTransaction>> getTransactions({
    String? cursor,
    int limit = 20,
  }) async {
    await gate();
    final all = List<WalletTransaction>.of(
      db.walletTransactions[currentUser.id] ?? const <WalletTransaction>[],
    )..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final start = cursor == null
        ? 0
        : all.indexWhere((WalletTransaction t) => t.id == cursor) + 1;
    return all.skip(start).take(limit).toList();
  }

  @override
  Future<WalletTransaction> requestWithdrawal(Money amount) async {
    await gate();
    final summary = await getSummary();
    final pack = db.countryPacks[currentUser.countryCode]!;
    final min = pack.minWithdrawal;
    if (min != null && amount < min) {
      throw const AppError(ErrorCodes.withdrawalBelowMinimum);
    }
    if (amount > summary.available) {
      throw const AppError(ErrorCodes.insufficientBalance);
    }
    // Mock of the finance-approval threshold (configurable per country).
    final threshold = Money.fromMajorUnits(500, 'USD');
    if (amount.minorUnits > threshold.minorUnits &&
        amount.currencyCode == 'USD') {
      throw const AppError(ErrorCodes.withdrawalNeedsApproval);
    }
    final txn = WalletTransaction(
      id: 'txn-${DateTime.now().millisecondsSinceEpoch}',
      kind: WalletTransactionKind.payout,
      status: WalletTransactionStatus.pending,
      amount: amount,
      descriptionKey: 'txnWithdrawal',
      createdAt: DateTime.now(),
    );
    db.walletTransactions
        .putIfAbsent(currentUser.id, () => <WalletTransaction>[])
        .add(txn);
    return txn;
  }

  String _currency() =>
      db.countryPacks[currentUser.countryCode]?.currencyCode ?? 'NGN';
}

class MockReferralRepository extends _MockRepo implements ReferralRepository {
  MockReferralRepository(super.db, super.behavior);

  @override
  Future<ReferralSummary> getSummary() async {
    await gate();
    return db.referrals[currentUser.id] ??
        ReferralSummary(
          code: 'NEW-USER',
          shareLink: 'https://suskii.app/r/NEW-USER',
          invitedCount: 0,
          activeReferrals: 0,
          earnedTotal: Money(0, _currency()),
          holding: Money(0, _currency()),
          available: Money(0, _currency()),
        );
  }

  @override
  Future<WalletTransaction> requestWithdrawal(Money amount) async {
    await gate();
    final summary = await getSummary();
    if (amount > summary.available) {
      throw const AppError(ErrorCodes.insufficientBalance);
    }
    return WalletTransaction(
      id: 'txn-ref-${DateTime.now().millisecondsSinceEpoch}',
      kind: WalletTransactionKind.referral,
      status: WalletTransactionStatus.pending,
      amount: amount,
      descriptionKey: 'txnReferralWithdrawal',
      createdAt: DateTime.now(),
    );
  }

  String _currency() =>
      db.countryPacks[currentUser.countryCode]?.currencyCode ?? 'NGN';
}

class MockCatalogRepository extends _MockRepo implements CatalogRepository {
  MockCatalogRepository(super.db, super.behavior);

  @override
  Future<List<ServiceCategory>> getCategories() async {
    await gate();
    return List<ServiceCategory>.unmodifiable(db.categories);
  }

  @override
  Future<CountryPack> getCountryPack(String countryCode) async {
    await gate();
    final pack = db.countryPacks[countryCode];
    if (pack == null) throw const AppError(ErrorCodes.countryDisabled);
    return pack;
  }
}

/// Canned concierge replies; the real one streams from the Gemini-backed AI
/// service (milestone M3 for the UI, Claude Code's Phase 7 for the backend).
class MockConciergeRepository extends _MockRepo implements ConciergeRepository {
  MockConciergeRepository(super.db, super.behavior);

  @override
  Stream<String> sendMessage(String conversationId, String text) async* {
    await gate();
    const reply =
        'Sure — tell me the pickup location, where it is going, and your price, '
        'and I will structure the request for you.';
    for (final word in reply.split(' ')) {
      await Future<void>.delayed(const Duration(milliseconds: 40));
      yield '$word ';
    }
  }
}

/// Simulated identity-verification vendor. Stands in for the Smile ID SDK
/// until spike S-05 picks the version; [MockBehavior.failLiveness] forces the
/// failure path with a localizable reason key.
class MockIdentityVerificationAdapter extends _MockRepo
    implements IdentityVerificationAdapter {
  MockIdentityVerificationAdapter(super.db, super.behavior);

  @override
  Future<LivenessSession> startLivenessSession() async {
    await gate();
    return LivenessSession(
      sessionId: 'liveness-${DateTime.now().millisecondsSinceEpoch}',
      expiresAt: DateTime.now().add(const Duration(minutes: 10)),
    );
  }

  @override
  Future<LivenessResult> captureLiveness(String sessionId) async {
    await gate();
    if (behavior.failLiveness) {
      return const LivenessResult(
        outcome: IdentityCheckOutcome.failed,
        reasonKey: 'livenessCheckFailed',
      );
    }
    return const LivenessResult(outcome: IdentityCheckOutcome.success);
  }

  @override
  Future<IdMatchResult> matchGovernmentId(
    String sessionId,
    String idType,
    String idNumber,
  ) async {
    await gate();
    return IdMatchResult(
      outcome: IdentityCheckOutcome.success,
      matchedName: currentUser.displayName,
    );
  }
}

/// Customer facial-verification flow. Consent is gated server-side:
/// [startFacialVerification] throws ERR_CONSENT_REQUIRED until
/// [giveBiometricConsent] has been called. [submitIdLookup] moves the session
/// to in-review and flips it to verified after [MockBehavior.kycReviewDelay]
/// so the UI can demo the in-review → verified transition.
class MockVerificationRepository extends _MockRepo
    implements VerificationRepository {
  MockVerificationRepository(super.db, super.behavior);

  final StreamController<VerificationSession?> _controller =
      StreamController<VerificationSession?>.broadcast();
  Timer? _reviewTimer;

  @override
  Future<VerificationSession?> getCustomerVerification() async {
    await gate();
    return db.verificationSessions[behavior.currentUserId];
  }

  @override
  Stream<VerificationSession?> watchCustomerVerification() async* {
    yield db.verificationSessions[behavior.currentUserId];
    yield* _controller.stream;
  }

  @override
  Future<VerificationSession> giveBiometricConsent() async {
    await gate();
    final now = DateTime.now();
    final session = VerificationSession(
      id: 'vs-${behavior.currentUserId}',
      kind: KycStepKind.customerFacial,
      status: KycStepStatus.inProgress,
      updatedAt: now,
      expiresAt: now.add(const Duration(minutes: 30)),
    );
    db.verificationSessions[behavior.currentUserId] = session;
    _controller.add(session);
    return session;
  }

  @override
  Future<VerificationSession> startFacialVerification() async {
    await gate();
    final session = db.verificationSessions[behavior.currentUserId];
    if (session == null || session.status == KycStepStatus.consentPending) {
      throw const AppError(ErrorCodes.consentRequired);
    }
    if (session.status == KycStepStatus.verified) return session;
    final updated = session.copyWith(
      status: KycStepStatus.inProgress,
      updatedAt: DateTime.now(),
    );
    db.verificationSessions[behavior.currentUserId] = updated;
    _controller.add(updated);
    return updated;
  }

  @override
  Future<VerificationSession> submitIdLookup(
    String sessionId,
    String idType,
    String idNumber,
  ) async {
    await gate();
    final session = db.verificationSessions[behavior.currentUserId];
    if (session == null ||
        session.id != sessionId ||
        session.status != KycStepStatus.inProgress) {
      throw const AppError(ErrorCodes.kycStepInvalid);
    }
    final inReview = session.copyWith(
      status: KycStepStatus.inReview,
      updatedAt: DateTime.now(),
    );
    db.verificationSessions[behavior.currentUserId] = inReview;
    _controller.add(inReview);
    _reviewTimer?.cancel();
    _reviewTimer = Timer(behavior.kycReviewDelay, () {
      final verified = inReview.copyWith(
        status: KycStepStatus.verified,
        updatedAt: DateTime.now(),
      );
      db.verificationSessions[behavior.currentUserId] = verified;
      final user = db.users[behavior.currentUserId];
      if (user != null) {
        db.users[user.id] = user.copyWith(
          customerVerification: VerificationStatus.verified,
        );
      }
      _controller.add(verified);
    });
    return inReview;
  }
}

/// Provider KYC state machine. Steps start not-started; [submitStep] moves a
/// step to in-review and flips it to verified after
/// [MockBehavior.kycReviewDelay] — except police clearance with an expired
/// certificate, which the "server" rejects immediately with a reason key.
class MockProviderKycRepository extends _MockRepo
    implements ProviderKycRepository {
  MockProviderKycRepository(super.db, super.behavior);

  final Map<KycStepKind, Timer> _reviewTimers = <KycStepKind, Timer>{};

  static const List<KycStepKind> _providerSteps = <KycStepKind>[
    KycStepKind.governmentId,
    KycStepKind.providerFacial,
    KycStepKind.idDocumentCapture,
    KycStepKind.policeClearance,
    KycStepKind.address,
    KycStepKind.guarantor,
    KycStepKind.payoutAccount,
    KycStepKind.vehicleDocuments,
    KycStepKind.credentials,
  ];

  static const Set<VehicleType> _motorized = <VehicleType>{
    VehicleType.motorcycle,
    VehicleType.tricycle,
    VehicleType.car,
    VehicleType.van,
    VehicleType.truck,
  };

  ProviderKycProfile _profile() {
    final user = currentUser;
    return db.kycProfiles.putIfAbsent(
      user.id,
      () => ProviderKycProfile(
        userId: user.id,
        kind: ProviderKind.individual,
        serviceCategoryIds: const <String>[],
        serviceAreaIds: const <String>[],
        steps: _providerSteps
            .map(
              (KycStepKind kind) => KycStep(
                kind: kind,
                status: KycStepStatus.notStarted,
                attemptCount: 0,
              ),
            )
            .toList(),
        overallStatus: KycStepStatus.notStarted,
      ),
    );
  }

  @override
  Future<ProviderKycProfile> getKycProfile() async {
    await gate();
    return _profile();
  }

  @override
  Stream<ProviderKycProfile> watchKycProfile() async* {
    yield _profile();
    yield* db.kycEvents.stream.where(
      (ProviderKycProfile p) => p.userId == behavior.currentUserId,
    );
  }

  @override
  Future<ProviderKycProfile> saveOnboarding(
    ProviderOnboardingInput input,
  ) async {
    await gate();
    final profile = _profile();
    final updated = profile.copyWith(
      kind: input.kind,
      serviceCategoryIds: input.serviceCategoryIds,
      serviceAreaIds: input.serviceAreaIds,
      vehicleType: input.vehicleType,
    );
    _store(updated);
    return updated;
  }

  bool _validInput(KycStepKind kind, Object input) => switch (kind) {
    KycStepKind.governmentId => input is IdDocumentInput,
    KycStepKind.providerFacial => input is String,
    KycStepKind.idDocumentCapture =>
      input is IdDocumentInput && input.uploadRef != null,
    KycStepKind.policeClearance => input is PoliceClearanceInput,
    KycStepKind.address => input is AddressInput,
    KycStepKind.guarantor => input is GuarantorInput,
    KycStepKind.payoutAccount => input is PayoutAccountInput,
    KycStepKind.vehicleDocuments => input is VehicleDocumentsInput,
    KycStepKind.credentials => input is CredentialsInput,
    KycStepKind.customerFacial => false,
  };

  @override
  Future<ProviderKycProfile> submitStep(KycStepKind kind, Object input) async {
    await gate();
    final profile = _profile();
    final index = profile.steps.indexWhere((KycStep s) => s.kind == kind);
    if (index < 0 || !_validInput(kind, input)) {
      throw const AppError(ErrorCodes.kycStepInvalid);
    }
    final step = profile.steps[index];
    if (step.status == KycStepStatus.inReview ||
        step.status == KycStepStatus.verified) {
      throw const AppError(ErrorCodes.kycStepInvalid);
    }
    final now = DateTime.now();
    // "Server-side" document validation: an expired police clearance
    // certificate is rejected with a localizable reason key.
    if (kind == KycStepKind.policeClearance &&
        (input as PoliceClearanceInput).expiryDate.isBefore(now)) {
      final rejected = step.copyWith(
        status: KycStepStatus.rejected,
        submittedAt: now,
        reviewedAt: now,
        rejectionReasonKey: 'kycRejectPoliceClearanceExpired',
        attemptCount: step.attemptCount + 1,
      );
      return _replaceStep(profile, index, rejected);
    }
    final inReview = step.copyWith(
      status: KycStepStatus.inReview,
      submittedAt: now,
      attemptCount: step.attemptCount + 1,
    );
    final updated = _replaceStep(profile, index, inReview);
    _reviewTimers[kind]?.cancel();
    _reviewTimers[kind] = Timer(behavior.kycReviewDelay, () {
      final current = db.kycProfiles[behavior.currentUserId];
      if (current == null) return;
      final i = current.steps.indexWhere((KycStep s) => s.kind == kind);
      if (i < 0 || current.steps[i].status != KycStepStatus.inReview) return;
      final verified = current.steps[i].copyWith(
        status: KycStepStatus.verified,
        reviewedAt: DateTime.now(),
      );
      _replaceStep(current, i, verified);
    });
    return updated;
  }

  @override
  Future<PayoutAccountResult> resolvePayoutAccount(
    PayoutAccountInput input,
  ) async {
    await gate();
    final match = !input.accountNumber.endsWith('00');
    final last4 = input.accountNumber.length > 4
        ? input.accountNumber.substring(input.accountNumber.length - 4)
        : input.accountNumber;
    return PayoutAccountResult(
      bankCode: input.bankCode,
      maskedAccountNumber: '••••$last4',
      resolvedName: match ? currentUser.displayName : 'Chukwuemeka Okafor',
      nameMatch: match,
    );
  }

  Set<KycStepKind> _requiredSteps(ProviderKycProfile profile) {
    final required = <KycStepKind>{
      KycStepKind.governmentId,
      KycStepKind.providerFacial,
      KycStepKind.idDocumentCapture,
      KycStepKind.policeClearance,
      KycStepKind.guarantor,
      KycStepKind.payoutAccount,
    };
    final vehicle = profile.vehicleType;
    if (vehicle != null && _motorized.contains(vehicle)) {
      required.add(KycStepKind.vehicleDocuments);
    }
    return required;
  }

  @override
  Future<ProviderKycProfile> submitForReview() async {
    await gate();
    final profile = _profile();
    final required = _requiredSteps(profile);
    final incomplete = profile.steps.where(
      (KycStep s) =>
          required.contains(s.kind) &&
          s.status != KycStepStatus.verified &&
          s.status != KycStepStatus.inReview,
    );
    if (incomplete.isNotEmpty) {
      throw const AppError(ErrorCodes.kycIncomplete);
    }
    final updated = profile.copyWith(
      overallStatus: KycStepStatus.inReview,
      submittedForReviewAt: DateTime.now(),
    );
    _store(updated);
    final user = currentUser;
    db.users[user.id] = user.copyWith(
      providerVerification: VerificationStatus.inReview,
    );
    return updated;
  }

  ProviderKycProfile _replaceStep(
    ProviderKycProfile profile,
    int index,
    KycStep step,
  ) {
    final steps = List<KycStep>.of(profile.steps);
    steps[index] = step;
    final updated = profile.copyWith(
      steps: steps,
      overallStatus: _rollup(profile, steps),
    );
    _store(updated);
    return updated;
  }

  KycStepStatus _rollup(ProviderKycProfile profile, List<KycStep> steps) {
    if (steps.any((KycStep s) => s.status == KycStepStatus.rejected)) {
      return KycStepStatus.rejected;
    }
    // Once submitted, officer review owns the overall status.
    if (profile.submittedForReviewAt != null) return KycStepStatus.inReview;
    if (steps.every((KycStep s) => s.status == KycStepStatus.notStarted)) {
      return KycStepStatus.notStarted;
    }
    if (steps.any((KycStep s) => s.status == KycStepStatus.inReview)) {
      return KycStepStatus.inReview;
    }
    if (steps.every((KycStep s) => s.status == KycStepStatus.verified)) {
      return KycStepStatus.verified;
    }
    return KycStepStatus.inProgress;
  }

  void _store(ProviderKycProfile profile) {
    db.kycProfiles[profile.userId] = profile;
    db.kycEvents.add(profile);
  }
}
