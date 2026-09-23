import 'dart:async';

import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_domain/suskii_domain.dart';

import 'fixtures.dart';
import 'mock_behavior.dart';
import 'server_sim.dart';

/// Mock record ids. The millisecond clock alone is not unique: two records
/// minted in the same millisecond collide, and because these ids key the
/// in-memory maps, a collision silently overwrites the earlier record. The
/// sequence makes them unique without changing the readable `prefix-…` shape.
int _mockIdSeq = 0;
String _mockId(String prefix) =>
    '$prefix-${DateTime.now().millisecondsSinceEpoch}-${++_mockIdSeq}';

/// Base class wiring the shared behavior gate (latency/offline/failure).
abstract class _MockRepo {
  _MockRepo(this.db, this.behavior);

  final MockDatabase db;
  final MockBehavior behavior;

  Future<void> gate() => behavior.gate();

  /// Stored results of completed mutating calls, keyed `'$operation:$key'`,
  /// together with the argument hash of the original call.
  /// Mirrors the backend's idempotency layer (spike S-10): presenting the
  /// same key again for the same operation with the SAME payload replays the
  /// first result without re-executing the side effect; the same key with a
  /// DIFFERENT payload is refused with ERR_IDEMPOTENCY_KEY_REUSED. Only
  /// successes are stored — a failed intent may be retried with the same key.
  final Map<String, (String, Object)> _idempotentResults =
      <String, (String, Object)>{};

  Future<T> idempotent<T extends Object>(
    String operation,
    String key,
    Future<T> Function() run, {
    String argsHash = '',
  }) async {
    final storageKey = '$operation:$key';
    final cached = _idempotentResults[storageKey];
    if (cached != null) {
      if (cached.$1 != argsHash) {
        throw const AppError(ErrorCodes.idempotencyKeyReused);
      }
      return cached.$2 as T;
    }
    final result = await run();
    _idempotentResults[storageKey] = (argsHash, result);
    return result;
  }

  /// The simulated server clock: device time plus a configurable skew.
  /// TTLs (offers, requests, sessions) are always computed and evaluated
  /// against this, never raw device time.
  DateTime serverNow() => DateTime.now().toUtc().add(behavior.serverClockSkew);

  /// Per-category offer TTL (behavior override wins, else the category's
  /// `offerTtlSeconds`). Shared by the offer repo and the provider repo's
  /// submitOffer so both mint offers with identical expiry semantics.
  Duration offerTtlFor(String categoryId) =>
      behavior.offerTtlOverride ??
      Duration(
        seconds: db.categories
            .firstWhere(
              (ServiceCategory c) => c.id == categoryId,
              orElse: () => db.categories.last,
            )
            .offerTtlSeconds,
      );

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
      voiceLanguages: kMockVoiceLanguages,
      minSupportedAppVersion: '0.1.0',
      serverTime: serverNow(),
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
  Future<UserMode> setActiveMode(
    UserMode mode, {
    required String idempotencyKey,
  }) async {
    await gate();
    return idempotent('setActiveMode', idempotencyKey, () async {
      final user = currentUser;
      if (mode == UserMode.provider &&
          user.providerVerification != VerificationStatus.verified) {
        throw const AppError(ErrorCodes.providerNotVerified);
      }
      final updated = user.copyWith(activeMode: mode);
      db.users[user.id] = updated;
      _controller.add(updated);
      return mode;
    }, argsHash: '$mode');
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
  Future<JobRequest> createRequest(
    CreateRequestInput input, {
    required String idempotencyKey,
  }) async {
    await gate();
    return idempotent(
      'createRequest',
      idempotencyKey,
      () async {
        final user = currentUser;
        // Drafts are free: unverified customers may create them (and use the
        // concierge). Verification gates publishRequest, not create.
        final id = _mockId('req');
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
          status: JobStatus.draft,
          createdAt: serverNow(),
          scheduledAt: input.scheduledAt,
          preferredPrice: input.preferredPrice,
          itemFloat: input.itemFloat,
          declaredValue: input.declaredValue,
        );
        db.requests[id] = request;
        db.jobEvents.add(request);
        return request;
      },
      argsHash:
          '${input.categoryId}|${input.isCustomCategory}|${input.description}'
          '|${input.mediaPaths.join(',')}'
          '|${input.pickup.label}|${input.pickup.landmarkNote}'
          '|${input.destination?.label}|${input.destination?.landmarkNote}'
          '|${input.scheduledAt?.toIso8601String()}|${input.urgency}'
          '|${input.preferredPrice?.minorUnits} '
          '${input.preferredPrice?.currencyCode}'
          '|${input.itemFloat?.minorUnits} ${input.itemFloat?.currencyCode}'
          '|${input.declaredValue?.minorUnits} '
          '${input.declaredValue?.currencyCode}',
    );
  }

  @override
  Future<JobRequest> publishRequest(
    String jobId, {
    required String idempotencyKey,
  }) async {
    await gate();
    return idempotent('publishRequest:$jobId', idempotencyKey, () async {
      final user = currentUser;
      if (user.customerVerification != VerificationStatus.verified) {
        throw const AppError(ErrorCodes.verificationRequired);
      }
      final request = db.requests[jobId];
      if (request == null || request.status != JobStatus.draft) {
        throw const AppError(ErrorCodes.permissionDenied);
      }
      final updated = request.copyWith(
        status: JobStatus.published,
        expiresAt: serverNow().add(const Duration(hours: 4)),
      );
      db.requests[jobId] = updated;
      db.jobEvents.add(updated);
      return updated;
    });
  }

  @override
  Future<JobRequest> cancelRequest(
    String jobId,
    String reasonKey, {
    required String idempotencyKey,
  }) async {
    await gate();
    return idempotent('cancelRequest:$jobId', idempotencyKey, () async {
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
    }, argsHash: reasonKey);
  }
}

class MockOfferRepository extends _MockRepo implements OfferRepository {
  MockOfferRepository(super.db, super.behavior);

  final List<Timer> _timers = <Timer>[];

  int _maxRounds(String categoryId) => db.categories
      .firstWhere(
        (ServiceCategory c) => c.id == categoryId,
        orElse: () => db.categories.last,
      )
      .maxCounterRounds;

  @override
  Stream<List<Offer>> watchOffers(String requestId) {
    late StreamController<List<Offer>> controller;
    controller = StreamController<List<Offer>>(
      onListen: () {
        void emit() => controller.add(
          List<Offer>.unmodifiable(db.offers[requestId] ?? const <Offer>[]),
        );
        emit();
        final request = db.requests[requestId];
        // Simulated realtime: while the request is collecting offers, 2–3
        // incoming offers arrive staggered from fixture providers (varied
        // amounts, ratings, distances, ETAs).
        if (request != null &&
            (request.status == JobStatus.published ||
                request.status == JobStatus.negotiating ||
                request.status == JobStatus.offersReceived)) {
          final existing = db.offers[requestId] ?? const <Offer>[];
          final base = request.preferredPrice ?? const Money(400000, 'NGN');
          final candidates =
              <(String, String, double, TrustLevel, double, int, int)>[
                    (
                      'provider-ngozi',
                      'Ngozi Adeyemi',
                      4.9,
                      TrustLevel.elite,
                      1.05,
                      1500,
                      9,
                    ),
                    (
                      'provider-kwame',
                      'Kwame Asante',
                      4.6,
                      TrustLevel.verified,
                      0.92,
                      3100,
                      18,
                    ),
                    (
                      'provider-musa',
                      'Musa Bello',
                      4.7,
                      TrustLevel.verified,
                      1.18,
                      800,
                      6,
                    ),
                  ]
                  .where(
                    (c) => !existing.any((Offer o) => o.providerId == c.$1),
                  )
                  .toList();
          const delays = <Duration>[
            Duration(seconds: 5),
            Duration(seconds: 9),
            Duration(seconds: 13),
          ];
          for (var i = 0; i < candidates.length && i < delays.length; i++) {
            final c = candidates[i];
            _timers.add(
              Timer(delays[i], () {
                final current = db.requests[requestId];
                if (current == null ||
                    !(current.status == JobStatus.published ||
                        current.status == JobStatus.negotiating ||
                        current.status == JobStatus.offersReceived)) {
                  return;
                }
                final amount = Money(
                  (base.minorUnits * c.$5).round(),
                  base.currencyCode,
                );
                final offer = Offer(
                  id: 'offer-live-${DateTime.now().millisecondsSinceEpoch}-$i',
                  requestId: requestId,
                  providerId: c.$1,
                  providerName: c.$2,
                  providerRating: c.$3,
                  providerTrustLevel: c.$4,
                  amount: amount,
                  status: OfferStatus.pending,
                  round: 1,
                  createdAt: serverNow(),
                  message: 'I can start immediately.',
                  distanceMeters: c.$6,
                  etaMinutes: c.$7,
                  payoutEstimate: simulateQuote(
                    amount,
                    estimatedGatewayFee: Money(
                      roundHalfEven(amount.minorUnits * 15, 1000),
                      amount.currencyCode,
                    ),
                  ),
                  expiresAt: serverNow().add(offerTtlFor(current.categoryId)),
                );
                db.offers.putIfAbsent(requestId, () => <Offer>[]).add(offer);
                db.offerEvents.add(offer);
                // State machine: first offer moves PUBLISHED → OFFERS_RECEIVED.
                if (current.status == JobStatus.published) {
                  final updated = current.copyWith(
                    status: JobStatus.offersReceived,
                  );
                  db.requests[requestId] = updated;
                  db.jobEvents.add(updated);
                }
                emit();
              }),
            );
          }
        }
        // TTL worker: pending/countered offers past expiresAt (server clock)
        // flip to expired. Expiry has no client entry point — this plays the
        // scheduled worker.
        _timers.add(
          Timer.periodic(const Duration(milliseconds: 500), (_) {
            final list = db.offers[requestId];
            if (list == null) return;
            var changed = false;
            for (var i = 0; i < list.length; i++) {
              final o = list[i];
              final live =
                  o.status == OfferStatus.pending ||
                  o.status == OfferStatus.countered;
              if (live &&
                  o.expiresAt != null &&
                  o.expiresAt!.isBefore(serverNow())) {
                list[i] = o.copyWith(status: OfferStatus.expired);
                db.offerEvents.add(list[i]);
                changed = true;
              }
            }
            if (changed) emit();
          }),
        );
      },
      onCancel: () {
        for (final t in _timers) {
          t.cancel();
        }
        _timers.clear();
        unawaited(controller.close());
      },
    );
    return controller.stream;
  }

  @override
  Future<Offer> acceptOffer(
    String offerId, {
    required String idempotencyKey,
  }) async {
    await gate();
    return idempotent('acceptOffer:$offerId', idempotencyKey, () async {
      final (requestId, index, offer) = _find(offerId);
      if (offer.status == OfferStatus.expired ||
          (offer.expiresAt != null && offer.expiresAt!.isBefore(serverNow()))) {
        throw const AppError(ErrorCodes.offerExpired);
      }
      // One transaction: accept this offer, expire all siblings, agree the job.
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
        // Server-generated handover PIN (the mock's known PIN is 4281).
        handoverPin: '4281',
      );
      db.requests[requestId] = updated;
      db.jobEvents.add(updated);
      db.offerEvents.add(accepted);
      return accepted;
    });
  }

  @override
  Future<Offer> declineOffer(
    String offerId, {
    required String idempotencyKey,
  }) async {
    await gate();
    return idempotent('declineOffer:$offerId', idempotencyKey, () async {
      final (requestId, index, offer) = _find(offerId);
      final declined = offer.copyWith(status: OfferStatus.declined);
      db.offers[requestId]![index] = declined;
      db.offerEvents.add(declined);
      return declined;
    });
  }

  @override
  Future<Offer> withdrawOffer(
    String offerId, {
    required String idempotencyKey,
  }) async {
    await gate();
    return idempotent('withdrawOffer:$offerId', idempotencyKey, () async {
      final (requestId, index, offer) = _find(offerId);
      if (offer.status != OfferStatus.pending) {
        throw const AppError(ErrorCodes.permissionDenied);
      }
      final withdrawn = offer.copyWith(status: OfferStatus.withdrawn);
      db.offers[requestId]![index] = withdrawn;
      db.offerEvents.add(withdrawn);
      return withdrawn;
    });
  }

  @override
  Future<Offer> counterOffer({
    required String offerId,
    required Money amount,
    required String idempotencyKey,
    String? message,
  }) async {
    await gate();
    return idempotent(
      'counterOffer:$offerId',
      idempotencyKey,
      () async {
        final (requestId, index, offer) = _find(offerId);
        final categoryId = db.requests[requestId]!.categoryId;
        if (offer.round >= _maxRounds(categoryId)) {
          throw const AppError(ErrorCodes.offerRoundsExhausted);
        }
        if (offer.status == OfferStatus.expired ||
            (offer.expiresAt != null &&
                offer.expiresAt!.isBefore(serverNow()))) {
          throw const AppError(ErrorCodes.offerExpired);
        }
        // TTL resets on each counter so the counterparty has time to respond.
        final countered = offer.copyWith(
          status: OfferStatus.countered,
          amount: amount,
          message: message,
          round: offer.round + 1,
          expiresAt: serverNow().add(offerTtlFor(categoryId)),
        );
        db.offers[requestId]![index] = countered;
        db.offerEvents.add(countered);
        return countered;
      },
      argsHash:
          '${amount.minorUnits} ${amount.currencyCode}'
          '|${message ?? ''}',
    );
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

  /// The real feed is country- and city-scoped server-side (Phase 3
  /// matching); the mock keeps one country per signed-in provider by matching
  /// the requesting customer's country.
  bool _inProviderCountry(JobRequest r) =>
      db.users[r.customerId]?.countryCode == currentUser.countryCode;

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
          .where(
            (JobRequest r) =>
                r.status == JobStatus.published && _inProviderCountry(r),
          )
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
            .where(
              (JobRequest r) =>
                  r.status == JobStatus.published && _inProviderCountry(r),
            )
            .toList();
        controller.add(snapshot());
        // Simulated realtime: a new nearby request appears periodically, in
        // the provider's own country/currency like the server-side feed.
        timer = Timer.periodic(const Duration(seconds: 25), (_) {
          final user = currentUser;
          final pack = db.countryPacks[user.countryCode];
          final currency = pack?.currencyCode ?? 'NGN';
          final city = pack != null && pack.launchCities.isNotEmpty
              ? pack.launchCities.first
              : 'downtown';
          final customer = db.users.values.firstWhere(
            (AppUser u) => u.countryCode == user.countryCode,
            orElse: () => db.users['user-chidi']!,
          );
          final id = _mockId('req-live');
          final request = JobRequest(
            id: id,
            customerId: customer.id,
            categoryId: 'errands_delivery',
            isCustomCategory: false,
            description: 'Pick up a cake from a bakery in $city.',
            mediaPaths: const <String>[],
            pickup: PlaceRef(
              label: 'Bakery, $city',
              point: const GeoPoint(latitude: 6.4281, longitude: 3.4219),
            ),
            urgency: Urgency.standard,
            status: JobStatus.published,
            createdAt: DateTime.now(),
            preferredPrice: Money(300000, currency),
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

  List<JobRequest> _myActiveJobs() =>
      db.requests.values
          .where(
            (JobRequest r) =>
                r.providerId == currentUser.id && !r.status.isTerminal,
          )
          .toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  @override
  Stream<List<JobRequest>> watchMyJobs() {
    late StreamController<List<JobRequest>> controller;
    StreamSubscription<JobRequest>? jobEvents;
    controller = StreamController<List<JobRequest>>(
      onListen: () {
        void emit() => controller.add(List.unmodifiable(_myActiveJobs()));
        emit();
        jobEvents = db.jobEvents.stream.listen((_) => emit());
      },
      onCancel: () {
        unawaited(jobEvents?.cancel());
        unawaited(controller.close());
      },
    );
    return controller.stream;
  }

  @override
  Future<List<JobRequest>> getMyJobsHistory({
    String? cursor,
    int limit = 20,
  }) async {
    await gate();
    final history =
        db.requests.values
            .where(
              (JobRequest r) =>
                  r.providerId == currentUser.id && r.status.isTerminal,
            )
            .toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final start = cursor == null
        ? 0
        : history.indexWhere((JobRequest r) => r.id == cursor) + 1;
    return history.skip(start).take(limit).toList();
  }

  @override
  Future<Offer> submitOffer({
    required String requestId,
    required Money amount,
    required String idempotencyKey,
    String? message,
  }) async {
    await gate();
    return idempotent(
      'submitOffer:$requestId',
      idempotencyKey,
      () async {
        final request = db.requests[requestId];
        if (request == null) throw const AppError(ErrorCodes.unknown);
        if (request.customerId == currentUser.id) {
          throw const AppError(ErrorCodes.selfDealingBlocked);
        }
        final user = currentUser;
        final now = serverNow();
        final offer = Offer(
          id: _mockId('offer'),
          requestId: requestId,
          providerId: user.id,
          providerName: user.displayName,
          providerRating: 4.5,
          providerTrustLevel: user.trustLevel,
          amount: amount,
          status: OfferStatus.pending,
          round: 1,
          createdAt: now,
          message: message,
          payoutEstimate: simulateQuote(amount),
          // Server clock + the request's own category TTL — never a
          // hardcoded device-side duration.
          expiresAt: now.add(offerTtlFor(request.categoryId)),
        );
        db.offers.putIfAbsent(requestId, () => <Offer>[]).add(offer);
        db.offerEvents.add(offer);
        return offer;
      },
      argsHash:
          '${amount.minorUnits} ${amount.currencyCode}'
          '|${message ?? ''}',
    );
  }

  @override
  Future<bool> setOnline(bool online, {required String idempotencyKey}) async {
    await gate();
    return idempotent('setOnline', idempotencyKey, () async {
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
    }, argsHash: '$online');
  }
}

class MockJobProgressRepository extends _MockRepo
    implements JobProgressRepository {
  MockJobProgressRepository(super.db, super.behavior);

  /// Provider-settable targets (server: `set_job_status` accepts en_route,
  /// arrived, completed_by_provider only — in_progress is reached through the
  /// pickup PIN, never set directly).
  static const Map<JobStatus, Set<JobStatus>> _allowed =
      <JobStatus, Set<JobStatus>>{
        JobStatus.assigned: <JobStatus>{JobStatus.enRoute},
        JobStatus.enRoute: <JobStatus>{JobStatus.arrived},
        JobStatus.inProgress: <JobStatus>{JobStatus.completedByProvider},
      };

  @override
  Future<JobRequest> requestStatusChange(
    String jobId,
    JobStatus target, {
    required String idempotencyKey,
  }) async {
    await gate();
    return idempotent('requestStatusChange:$jobId', idempotencyKey, () async {
      final request = db.requests[jobId];
      if (request == null) throw const AppError(ErrorCodes.unknown);
      final allowedTargets = _allowed[request.status] ?? const <JobStatus>{};
      if (!allowedTargets.contains(target)) {
        throw const AppError(ErrorCodes.permissionDenied);
      }
      if (target == JobStatus.completedByProvider) {
        _requireCompletionProofs(request);
      }
      final updated = request.copyWith(status: target);
      db.requests[jobId] = updated;
      db.jobEvents.add(updated);
      return updated;
    }, argsHash: '$target');
  }

  /// Completion gate (spec: job_lifecycle.proof, mirrors the backend's
  /// `submit_proof` rules): every proof kind the category requires must have
  /// enough submissions, and a job with a destination needs its delivery PIN
  /// verified. Anything missing raises ERR_PROOF_REQUIRED.
  void _requireCompletionProofs(JobRequest request) {
    final requirements = db.categories
        .firstWhere(
          (ServiceCategory c) => c.id == request.categoryId,
          orElse: () => db.categories.last,
        )
        .proofRequirements;
    final submitted = db.proofs[request.id] ?? const <Proof>[];
    final missing = <String>[];
    requirements.forEach((String kind, int requiredCount) {
      final have = submitted
          .where((Proof p) => _proofKindWire(p.kind) == kind)
          .length;
      if (have < requiredCount) missing.add(kind);
    });
    if (request.destination != null &&
        !_verifiedPins.contains('${request.id}:delivery')) {
      missing.add('delivery_pin');
    }
    if (missing.isNotEmpty) {
      throw AppError(ErrorCodes.proofRequired, details: missing);
    }
  }

  /// ProofKind → wire value without depending on generated JSON helpers.
  static String _proofKindWire(ProofKind kind) => switch (kind) {
    ProofKind.photo => 'photo',
    ProofKind.receipt => 'receipt',
    ProofKind.signature => 'signature',
  };

  @override
  Future<Proof> submitProof({
    required String jobId,
    required ProofKind kind,
    required String storagePath,
    required String idempotencyKey,
    DateTime? capturedAt,
    double? lat,
    double? lng,
  }) async {
    await gate();
    return idempotent('submitProof:$jobId', idempotencyKey, () async {
      final request = db.requests[jobId];
      if (request == null) throw const AppError(ErrorCodes.unknown);
      if (request.providerId != currentUser.id) {
        throw const AppError(ErrorCodes.permissionDenied);
      }
      if (request.status != JobStatus.inProgress &&
          request.status != JobStatus.completedByProvider) {
        throw const AppError(ErrorCodes.invalidState);
      }
      // Storage objects are namespaced per job; the server signs uploads
      // only into the job's own prefix.
      if (!storagePath.startsWith('$jobId/')) {
        throw const AppError(ErrorCodes.permissionDenied);
      }
      final proof = Proof(
        id: _mockId('proof'),
        jobId: jobId,
        providerId: currentUser.id,
        kind: kind,
        storagePath: storagePath,
        createdAt: serverNow(),
        capturedAt: capturedAt,
        lat: lat,
        lng: lng,
      );
      db.proofs.putIfAbsent(jobId, () => <Proof>[]).add(proof);
      return proof;
    }, argsHash: '${_proofKindWire(kind)}|$storagePath');
  }

  @override
  Future<List<Proof>> getProofs(String jobId) async {
    await gate();
    final request = db.requests[jobId];
    if (request == null) throw const AppError(ErrorCodes.unknown);
    final me = currentUser.id;
    if (request.customerId != me && request.providerId != me) {
      throw const AppError(ErrorCodes.permissionDenied);
    }
    return List.unmodifiable(db.proofs[jobId] ?? const <Proof>[]);
  }

  @override
  Future<JobRequest> confirmCompletion(
    String jobId, {
    required String idempotencyKey,
  }) async {
    await gate();
    return idempotent('confirmCompletion:$jobId', idempotencyKey, () async {
      final request = db.requests[jobId];
      if (request == null) throw const AppError(ErrorCodes.unknown);
      if (request.status != JobStatus.completedByProvider) {
        throw const AppError(ErrorCodes.permissionDenied);
      }
      final updated = request.copyWith(status: JobStatus.confirmed);
      db.requests[jobId] = updated;
      db.jobEvents.add(updated);
      return updated;
    });
  }

  /// PIN attempt counters, keyed '$jobId:<kind>' — pickup and delivery are
  /// two different PINs with two different limits (mirrors verify_pin).
  final Map<String, int> _pinAttempts = <String, int>{};

  /// '$jobId:<kind>' entries whose PIN verified. The completion gate checks
  /// the delivery entry for jobs with a destination (delivery PIN gate).
  final Set<String> _verifiedPins = <String>{};

  @override
  Future<PinVerificationResult> verifyHandoverPin(
    String jobId,
    String pin, {
    required HandoverPinKind kind,
    required String idempotencyKey,
  }) async {
    await gate();
    return idempotent(
      'verifyHandoverPin:$jobId:${kind.name}',
      idempotencyKey,
      () async {
        final scope = '$jobId:${kind.name}';
        final attempts = _pinAttempts[scope] ?? 0;
        // Terminal: the attempt limit is its own error, not a denial.
        if (attempts >= 5) {
          throw const AppError(ErrorCodes.pinAttemptsExceeded);
        }
        final request = db.requests[jobId];
        if (request == null) throw const AppError(ErrorCodes.unknown);
        // A wrong PIN spends an attempt; replaying the same intent key does
        // not.
        final ok = pin == '4281';
        if (ok) {
          _verifiedPins.add(scope);
        } else {
          _pinAttempts[scope] = attempts + 1;
        }
        var status = request.status;
        if (ok &&
            kind == HandoverPinKind.pickup &&
            request.status == JobStatus.arrived) {
          // The pickup PIN is what starts the work (job lifecycle transition
          // 14): arrived → in_progress happens inside verify_pin; it is not a
          // settable target of requestStatusChange.
          final updated = request.copyWith(status: JobStatus.inProgress);
          db.requests[jobId] = updated;
          db.jobEvents.add(updated);
          status = JobStatus.inProgress;
        }
        return PinVerificationResult(
          verified: ok,
          status: status,
          attemptsRemaining: 5 - (ok ? attempts : attempts + 1),
        );
      },
      argsHash: '${kind.name}:$pin',
    );
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
    required String idempotencyKey,
    String? text,
    String? mediaPath,
    GeoPoint? location,
  }) async {
    await gate();
    return idempotent('chatSend:$jobId', idempotencyKey, () async {
      final message = ChatMessage(
        id: _mockId('msg'),
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
    }, argsHash: '$type|${text ?? ''}|${mediaPath ?? ''}');
  }
}

class MockPaymentRepository extends _MockRepo implements PaymentRepository {
  MockPaymentRepository(super.db, super.behavior);

  static const Duration _paymentTtl = Duration(minutes: 15);

  final List<Timer> _timers = <Timer>[];

  @override
  Future<Payment?> getPaymentForJob(String jobId) async {
    await gate();
    return db.payments[db.paymentByJob[jobId]];
  }

  @override
  Stream<Payment?> watchPaymentForJob(String jobId) {
    late StreamController<Payment?> controller;
    StreamSubscription<Payment>? sub;
    controller = StreamController<Payment?>(
      onListen: () {
        controller.add(db.payments[db.paymentByJob[jobId]]);
        sub = db.paymentEvents.stream
            .where((Payment p) => p.jobId == jobId)
            .listen(controller.add);
      },
      onCancel: () {
        unawaited(sub?.cancel());
        unawaited(controller.close());
      },
    );
    return controller.stream;
  }

  @override
  Future<PaymentSession> initializePayment({
    required String jobId,
    required PaymentMethod method,
    required String idempotencyKey,
  }) async {
    await gate();
    return idempotent('initializePayment:$jobId', idempotencyKey, () async {
      final user = currentUser;
      if (user.customerVerification != VerificationStatus.verified) {
        throw const AppError(ErrorCodes.verificationRequired);
      }
      final job = db.requests[jobId];
      if (job == null) throw const AppError(ErrorCodes.unknown);
      if (job.customerId != user.id) {
        throw const AppError(ErrorCodes.permissionDenied);
      }
      final agreed = job.agreedPrice;
      if (agreed == null ||
          (job.status != JobStatus.agreed &&
              job.status != JobStatus.paymentPending)) {
        throw const AppError(ErrorCodes.invalidState);
      }
      final existing = db.payments[db.paymentByJob[jobId]];
      if (existing != null && existing.status == PaymentStatus.held) {
        throw const AppError(ErrorCodes.invalidState);
      }
      // Retry within the TTL: return the in-flight payment (same as the
      // server returning the existing pending attempt).
      if (existing != null && existing.status == PaymentStatus.pending) {
        return PaymentSession(
          payment: existing,
          ussdCode: method == PaymentMethod.ussd ? '*737*000#...' : null,
          reference: method == PaymentMethod.bankTransfer
              ? existing.gatewayReference
              : null,
        );
      }
      final id = _mockId('pay');
      final payment = Payment(
        id: id,
        jobId: jobId,
        amount: agreed,
        method: method,
        status: PaymentStatus.pending,
        createdAt: serverNow(),
        gatewayReference: 'FLW-MOCK-$id',
        expiresAt: serverNow().add(_paymentTtl),
      );
      db.payments[id] = payment;
      db.paymentByJob[jobId] = id;
      final pendingJob = job.copyWith(
        status: JobStatus.paymentPending,
        expiresAt: payment.expiresAt,
      );
      db.requests[jobId] = pendingJob;
      db.jobEvents.add(pendingJob);
      db.paymentEvents.add(payment);

      // Simulated gateway webhook + server-side verify: the payment flips to
      // HELD (or FAILED with failure injection) and the job follows. The
      // client never marks anything itself — it watches these events.
      _timers.add(
        Timer(behavior.paymentConfirmDelay, () {
          if (behavior.failNextPayment) {
            behavior.failNextPayment = false;
            final failed = payment.copyWith(
              status: PaymentStatus.failed,
              failureReasonKey: 'paymentDeclined',
            );
            db.payments[id] = failed;
            db.paymentEvents.add(failed);
            // Back to AGREED so the customer can re-attempt payment.
            final back = (db.requests[jobId] ?? pendingJob).copyWith(
              status: JobStatus.agreed,
            );
            db.requests[jobId] = back;
            db.jobEvents.add(back);
            return;
          }
          final held = payment.copyWith(
            status: PaymentStatus.held,
            paidAt: serverNow(),
          );
          db.payments[id] = held;
          db.paymentEvents.add(held);
          final paidJob = (db.requests[jobId] ?? pendingJob).copyWith(
            status: JobStatus.paidHeld,
          );
          db.requests[jobId] = paidJob;
          db.jobEvents.add(paidJob);
        }),
      );

      return PaymentSession(
        payment: payment,
        ussdCode: method == PaymentMethod.ussd ? '*737*000#...' : null,
        reference: method == PaymentMethod.bankTransfer
            ? payment.gatewayReference
            : null,
      );
    }, argsHash: '$method');
  }
}

class MockRatingRepository extends _MockRepo implements RatingRepository {
  MockRatingRepository(super.db, super.behavior);

  static const Set<JobStatus> _rateable = <JobStatus>{
    JobStatus.confirmed,
    JobStatus.settled,
    JobStatus.closed,
  };

  @override
  Future<Rating?> getMyRatingForJob(String jobId) async {
    await gate();
    final user = currentUser;
    for (final rating in db.ratings[jobId] ?? const <Rating>[]) {
      if (rating.raterId == user.id) return rating;
    }
    return null;
  }

  @override
  Future<Rating> submitRating({
    required String jobId,
    required int stars,
    required String idempotencyKey,
    List<String> tagKeys = const <String>[],
    String? comment,
  }) async {
    await gate();
    return idempotent('submitRating:$jobId', idempotencyKey, () async {
      final user = currentUser;
      final job = db.requests[jobId];
      if (job == null) throw const AppError(ErrorCodes.unknown);
      final isCustomer = job.customerId == user.id;
      final isProvider = job.providerId == user.id;
      if (!isCustomer && !isProvider) {
        throw const AppError(ErrorCodes.permissionDenied);
      }
      if (!_rateable.contains(job.status) || stars < 1 || stars > 5) {
        throw const AppError(ErrorCodes.invalidState);
      }
      final list = db.ratings.putIfAbsent(jobId, () => <Rating>[]);
      if (list.any((Rating r) => r.raterId == user.id)) {
        throw const AppError(ErrorCodes.invalidState);
      }
      final rating = Rating(
        id: _mockId('rating'),
        jobId: jobId,
        raterId: user.id,
        rateeId: isCustomer ? job.providerId! : job.customerId,
        stars: stars,
        tagKeys: tagKeys,
        comment: comment,
        createdAt: serverNow(),
      );
      list.add(rating);
      return rating;
    }, argsHash: '$stars|${tagKeys.join(',')}|${comment ?? ''}');
  }
}

class MockSafetyRepository extends _MockRepo implements SafetyRepository {
  MockSafetyRepository(super.db, super.behavior);

  /// States in which SOS / trip sharing make sense (agreed onward, i.e. the
  /// parties are in contact or the job is being executed).
  static const Set<JobStatus> _activeJobStates = <JobStatus>{
    JobStatus.agreed,
    JobStatus.paymentPending,
    JobStatus.paidHeld,
    JobStatus.assigned,
    JobStatus.enRoute,
    JobStatus.arrived,
    JobStatus.inProgress,
    JobStatus.completedByProvider,
  };

  JobRequest _participantJob(String jobId) {
    final user = currentUser;
    final job = db.requests[jobId];
    if (job == null) throw const AppError(ErrorCodes.unknown);
    if (job.customerId != user.id && job.providerId != user.id) {
      throw const AppError(ErrorCodes.permissionDenied);
    }
    if (!_activeJobStates.contains(job.status)) {
      throw const AppError(ErrorCodes.invalidState);
    }
    return job;
  }

  @override
  Future<SosAlert> triggerSos({
    required String jobId,
    required String idempotencyKey,
    GeoPoint? location,
  }) async {
    await gate();
    return idempotent(
      'triggerSos:$jobId',
      idempotencyKey,
      () async {
        final user = currentUser;
        _participantJob(jobId);
        // SOS is naturally idempotent: a second trigger while one is active
        // returns the same alert rather than piling up alerts.
        final existing = db.sosAlerts[jobId];
        if (existing != null && existing.status == SosStatus.active) {
          return existing;
        }
        final alert = SosAlert(
          id: _mockId('sos'),
          jobId: jobId,
          triggeredBy: user.id,
          status: SosStatus.active,
          createdAt: serverNow(),
          location: location,
          // The mock "server" notifies 2 trusted contacts.
          trustedContactsNotified: 2,
        );
        db.sosAlerts[jobId] = alert;
        db.sosEvents.add(alert);
        return alert;
      },
      argsHash: location == null
          ? ''
          : '${location.latitude},${location.longitude}',
    );
  }

  @override
  Stream<SosAlert?> watchActiveSos(String jobId) {
    late StreamController<SosAlert?> controller;
    StreamSubscription<SosAlert>? sub;
    controller = StreamController<SosAlert?>(
      onListen: () {
        final current = db.sosAlerts[jobId];
        controller.add(
          current != null && current.status == SosStatus.active
              ? current
              : null,
        );
        sub = db.sosEvents.stream
            .where((SosAlert a) => a.jobId == jobId)
            .listen(
              (SosAlert a) =>
                  controller.add(a.status == SosStatus.active ? a : null),
            );
      },
      onCancel: () {
        unawaited(sub?.cancel());
        unawaited(controller.close());
      },
    );
    return controller.stream;
  }

  @override
  Future<TripShare> createTripShareLink(
    String jobId, {
    required String idempotencyKey,
  }) async {
    await gate();
    return idempotent('tripShare:$jobId', idempotencyKey, () async {
      _participantJob(jobId);
      return TripShare(
        url: 'https://track.suskii.invalid/t/$jobId',
        expiresAt: serverNow().add(const Duration(hours: 1)),
      );
    });
  }
}

class MockCallAdapter extends _MockRepo implements CallAdapter {
  MockCallAdapter(super.db, super.behavior);

  /// The spec window is provider-selected → 24h after completion; the mock
  /// approximates it with the job's in-contact states.
  static const Set<JobStatus> _callableStates = <JobStatus>{
    JobStatus.paidHeld,
    JobStatus.assigned,
    JobStatus.enRoute,
    JobStatus.arrived,
    JobStatus.inProgress,
    JobStatus.completedByProvider,
  };

  final Map<String, StreamController<CallEvent>> _controllers =
      <String, StreamController<CallEvent>>{};
  final Map<String, CallState> _states = <String, CallState>{};
  final Map<String, String> _sessionJobs = <String, String>{};
  final Set<String> _jobsInCall = <String>{};
  final List<Timer> _timers = <Timer>[];

  void _emit(String sessionId, CallState state) {
    _states[sessionId] = state;
    _controllers[sessionId]?.add(CallEvent(state: state));
  }

  @override
  Future<CallSession> startCall(
    String jobId, {
    required String idempotencyKey,
  }) async {
    await gate();
    return idempotent('startCall:$jobId', idempotencyKey, () async {
      final user = currentUser;
      final job = db.requests[jobId];
      if (job == null) throw const AppError(ErrorCodes.unknown);
      if (job.customerId != user.id && job.providerId != user.id) {
        throw const AppError(ErrorCodes.permissionDenied);
      }
      if (!_callableStates.contains(job.status)) {
        throw const AppError(ErrorCodes.permissionDenied);
      }
      // One active call per job (resolved server-side).
      if (_jobsInCall.contains(jobId)) {
        throw const AppError(ErrorCodes.callInProgress);
      }
      final sessionId = _mockId('call');
      _jobsInCall.add(jobId);
      _sessionJobs[sessionId] = jobId;
      _states[sessionId] = CallState.connecting;
      _controllers[sessionId] = StreamController<CallEvent>.broadcast();
      _timers.add(
        Timer(
          const Duration(milliseconds: 800),
          () => _emit(sessionId, CallState.ringing),
        ),
      );
      _timers.add(
        Timer(
          const Duration(seconds: 2),
          () => _emit(sessionId, CallState.active),
        ),
      );
      return CallSession(
        sessionId: sessionId,
        jobId: jobId,
        expiresAt: serverNow().add(const Duration(minutes: 5)),
      );
    });
  }

  @override
  Stream<CallEvent> events(String sessionId) {
    late StreamController<CallEvent> controller;
    StreamSubscription<CallEvent>? sub;
    controller = StreamController<CallEvent>(
      onListen: () {
        controller.add(
          CallEvent(state: _states[sessionId] ?? CallState.connecting),
        );
        sub = _controllers[sessionId]?.stream.listen(controller.add);
      },
      onCancel: () {
        unawaited(sub?.cancel());
        unawaited(controller.close());
      },
    );
    return controller.stream;
  }

  @override
  Future<void> setMuted(String sessionId, {required bool muted}) async {
    // Mute is local audio state on the real adapter; nothing to simulate.
  }

  @override
  Future<void> endCall(String sessionId) async {
    final jobId = _sessionJobs.remove(sessionId);
    if (jobId != null) _jobsInCall.remove(jobId);
    _emit(sessionId, CallState.ended);
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
  Future<WalletTransaction> requestWithdrawal(
    Money amount, {
    required String idempotencyKey,
  }) async {
    await gate();
    return idempotent('walletWithdrawal', idempotencyKey, () async {
      final summary = await getSummary();
      final pack = db.countryPacks[currentUser.countryCode]!;
      final min = pack.minWithdrawal;
      if (min != null && amount < min) {
        throw const AppError(ErrorCodes.withdrawalBelowMinimum);
      }
      if (amount > summary.available) {
        throw const AppError(ErrorCodes.insufficientBalance);
      }
      // Above the finance-approval threshold the withdrawal still succeeds —
      // it is created with an awaiting-approval status (contracts:
      // withdrawal_status = 'awaiting_approval'), it is NOT an error.
      final threshold = Money.fromMajorUnits(500, 'USD');
      final needsApproval =
          amount.minorUnits > threshold.minorUnits &&
          amount.currencyCode == 'USD';
      final txn = WalletTransaction(
        id: _mockId('txn'),
        kind: WalletTransactionKind.payout,
        status: WalletTransactionStatus.pending,
        amount: amount,
        descriptionKey: needsApproval
            ? 'txnWithdrawalAwaitingApproval'
            : 'txnWithdrawal',
        createdAt: DateTime.now(),
      );
      db.walletTransactions
          .putIfAbsent(currentUser.id, () => <WalletTransaction>[])
          .add(txn);
      return txn;
    }, argsHash: '${amount.minorUnits} ${amount.currencyCode}');
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
  Future<WalletTransaction> requestWithdrawal(
    Money amount, {
    required String idempotencyKey,
  }) async {
    await gate();
    return idempotent('referralWithdrawal', idempotencyKey, () async {
      final summary = await getSummary();
      if (amount > summary.available) {
        throw const AppError(ErrorCodes.insufficientBalance);
      }
      return WalletTransaction(
        id: _mockId('txn-ref'),
        kind: WalletTransactionKind.referral,
        status: WalletTransactionStatus.pending,
        amount: amount,
        descriptionKey: 'txnReferralWithdrawal',
        createdAt: DateTime.now(),
      );
    }, argsHash: '${amount.minorUnits} ${amount.currencyCode}');
  }

  String _currency() =>
      db.countryPacks[currentUser.countryCode]?.currencyCode ?? 'NGN';
}

class MockCatalogRepository extends _MockRepo implements CatalogRepository {
  MockCatalogRepository(super.db, super.behavior);

  /// Simulated price-intelligence bands (minor units, NGN scale; the mock
  /// returns them in the current user's country-pack currency).
  static const Map<String, (int, int, int, int, PriceBandConfidence)> _bands =
      <String, (int, int, int, int, PriceBandConfidence)>{
        'errands_delivery': (
          150000,
          300000,
          500000,
          214,
          PriceBandConfidence.high,
        ),
        'shopping': (250000, 500000, 900000, 187, PriceBandConfidence.high),
        'cleaning_laundry': (
          1500000,
          2500000,
          4000000,
          96,
          PriceBandConfidence.medium,
        ),
        'moving': (4000000, 7500000, 12000000, 61, PriceBandConfidence.medium),
        'food_pickup': (100000, 200000, 350000, 243, PriceBandConfidence.high),
        'document_delivery': (
          200000,
          400000,
          650000,
          74,
          PriceBandConfidence.medium,
        ),
      };

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

  @override
  Future<PriceBand?> getPriceBand({
    required String categoryId,
    Urgency urgency = Urgency.standard,
    String? cityId,
  }) async {
    await gate();
    final currency =
        db.countryPacks[currentUser.countryCode]?.currencyCode ?? 'NGN';
    final band =
        _bands[categoryId] ??
        (200000, 450000, 800000, 12, PriceBandConfidence.low);
    return PriceBand(
      p25: Money(band.$1, currency),
      p50: Money(band.$2, currency),
      p75: Money(band.$3, currency),
      sampleSize: band.$4,
      confidence: band.$5,
      // Cold start: only categories with completed-job history get a
      // history-based band; everything else is a rules-based rough guide.
      basis: _bands.containsKey(categoryId)
          ? PriceBandBasis.history
          : PriceBandBasis.rules,
    );
  }
}

/// Deterministic slot-filling concierge simulation. Turn 1 classifies the
/// category from keywords and takes the text as the description; turn 2
/// fills the pickup; turn 3 parses a price. The underlying draft [JobRequest]
/// is created from the first saved slot (same path as
/// [RequestRepository.createRequest]) and kept in sync as slots fill, so
/// `ConciergeDraft.requestId` is set early and half-finished drafts are
/// resumable (M3.10). When the draft is complete the assistant reply carries
/// `proposedAction: showPublishCard` — publishing then goes through
/// [RequestRepository.publishRequest], never through the concierge
/// (review M3.1). The full assistant message (with the updated draft) is
/// appended to the conversation after the streamed chunks complete.
class MockConciergeRepository extends _MockRepo implements ConciergeRepository {
  MockConciergeRepository(super.db, super.behavior);

  static const List<String> _allSlots = <String>[
    'category',
    'description',
    'pickup',
    'preferredPrice',
  ];

  final Map<String, List<ConciergeMessage>> _messages =
      <String, List<ConciergeMessage>>{};
  final Map<String, ConciergeDraft> _drafts = <String, ConciergeDraft>{};
  final Map<String, StreamController<List<ConciergeMessage>>> _controllers =
      <String, StreamController<List<ConciergeMessage>>>{};
  final Map<String, int> _turns = <String, int>{};

  static const ConciergeDraft _emptyDraft = ConciergeDraft(
    isCustomCategory: false,
    missingSlots: _allSlots,
  );

  @override
  Future<ConciergeConversation> startConversation({
    required String idempotencyKey,
  }) async {
    await gate();
    return idempotent('startConversation', idempotencyKey, () async {
      final conversation = ConciergeConversation(
        id: _mockId('conv'),
        createdAt: serverNow(),
        language: currentUser.preferredLanguage,
      );
      _messages[conversation.id] = <ConciergeMessage>[
        ConciergeMessage(
          id: 'cmsg-${conversation.id}-0',
          conversationId: conversation.id,
          role: ConciergeRole.assistant,
          text: 'Welcome! Tell me what you need done, in your own words.',
          createdAt: serverNow(),
          structuredDraft: _emptyDraft,
        ),
      ];
      _drafts[conversation.id] = _emptyDraft;
      _turns[conversation.id] = 0;
      return conversation;
    });
  }

  @override
  Stream<List<ConciergeMessage>> watchMessages(String conversationId) {
    final controller = _controllers.putIfAbsent(
      conversationId,
      StreamController<List<ConciergeMessage>>.broadcast,
    );
    unawaited(
      Future<void>.microtask(
        () => controller.add(
          List.unmodifiable(
            _messages[conversationId] ?? const <ConciergeMessage>[],
          ),
        ),
      ),
    );
    return controller.stream;
  }

  void _emit(String conversationId) {
    _controllers[conversationId]?.add(
      List.unmodifiable(
        _messages[conversationId] ?? const <ConciergeMessage>[],
      ),
    );
  }

  static const List<(String, String)> _keywords = <(String, String)>[
    ('clean', 'cleaning_laundry'),
    ('laundry', 'cleaning_laundry'),
    ('move', 'moving'),
    ('food', 'food_pickup'),
    ('order', 'food_pickup'),
    ('deliver', 'errands_delivery'),
    ('parcel', 'errands_delivery'),
    ('package', 'errands_delivery'),
    ('buy', 'shopping'),
    ('shop', 'shopping'),
    ('groceries', 'shopping'),
    ('document', 'document_delivery'),
  ];

  (String, bool) _classify(String text) {
    final lower = text.toLowerCase();
    for (final (keyword, categoryId) in _keywords) {
      if (lower.contains(keyword)) return (categoryId, false);
    }
    return ('custom', true);
  }

  @override
  Stream<String> sendMessage(
    String conversationId,
    String text, {
    required String idempotencyKey,
  }) async* {
    await gate();
    final messages = _messages[conversationId];
    final draft = _drafts[conversationId];
    if (messages == null || draft == null) {
      throw const AppError(ErrorCodes.unknown);
    }
    // Replay: the same intent key re-yields the stored assistant reply
    // without re-running slot filling or appending messages. The same key
    // carrying a DIFFERENT message is refused, like the backend.
    final cacheKey = 'conciergeSend:$idempotencyKey';
    final cached = _idempotentResults[cacheKey];
    if (cached != null) {
      if (cached.$1 != text) {
        throw const AppError(ErrorCodes.idempotencyKeyReused);
      }
      for (final word in (cached.$2 as String).split(' ')) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        yield '$word ';
      }
      return;
    }
    final turn = (_turns[conversationId] ?? 0) + 1;
    _turns[conversationId] = turn;
    messages.add(
      ConciergeMessage(
        id: 'cmsg-$conversationId-u$turn',
        conversationId: conversationId,
        role: ConciergeRole.user,
        text: text,
        createdAt: serverNow(),
      ),
    );

    final ConciergeDraft updated;
    final String reply;
    switch (turn) {
      case 1:
        final (categoryId, isCustom) = _classify(text);
        updated = draft.copyWith(
          categoryId: categoryId,
          isCustomCategory: isCustom,
          description: text,
          missingSlots: const <String>['pickup', 'preferredPrice'],
        );
        reply =
            'Got it. Where should this happen — what is the pickup or '
            'service location?';
      case 2:
        updated = draft.copyWith(
          pickup: PlaceRef(label: text),
          missingSlots: const <String>['preferredPrice'],
        );
        reply = 'Noted. And how much would you like to offer for this?';
      case 3:
        final digits = RegExp(r'\d+').firstMatch(text)?.group(0);
        final amount = digits == null ? null : int.parse(digits);
        final currency =
            db.countryPacks[currentUser.countryCode]?.currencyCode ?? 'NGN';
        updated = draft.copyWith(
          preferredPrice: amount == null
              ? null
              : Money.fromMajorUnits(amount, currency),
          missingSlots: amount == null
              ? const <String>['preferredPrice']
              : const <String>[],
        );
        reply = amount == null
            ? 'I did not catch an amount — what price works for you?'
            : 'All set. Review the summary and confirm to publish your request.';
      default:
        updated = draft;
        reply = updated.requestId != null
            ? 'Your request is ready — confirm to publish it.'
            : 'Anything else you want to add?';
    }

    // Server-side draft: the underlying draft JobRequest is created as soon
    // as the first slot is saved, so a half-finished concierge draft is
    // resumable (CU-01), and kept in sync as later turns fill more slots.
    // Publishing stays with RequestRepository.publishRequest
    // (verification-gated).
    var finalDraft = updated;
    if (updated.requestId == null && updated.categoryId != null) {
      final created = await MockRequestRepository(db, behavior).createRequest(
        CreateRequestInput(
          categoryId: updated.categoryId ?? 'custom',
          isCustomCategory: updated.isCustomCategory,
          description: updated.description ?? '',
          pickup: updated.pickup ?? const PlaceRef(label: ''),
          destination: updated.destination,
          urgency: updated.urgency ?? Urgency.standard,
          scheduledAt: updated.scheduledAt,
          preferredPrice: updated.preferredPrice,
          itemFloat: updated.itemFloat,
          declaredValue: updated.declaredValue,
        ),
        idempotencyKey: 'concierge-draft-$conversationId',
      );
      finalDraft = updated.copyWith(requestId: created.id);
    }
    final requestId = finalDraft.requestId;
    if (requestId != null) {
      final stored = db.requests[requestId];
      if (stored != null) {
        db.requests[requestId] = stored.copyWith(
          description: finalDraft.description ?? stored.description,
          pickup: finalDraft.pickup ?? stored.pickup,
          destination: finalDraft.destination,
          urgency: finalDraft.urgency ?? stored.urgency,
          scheduledAt: finalDraft.scheduledAt,
          preferredPrice: finalDraft.preferredPrice,
          itemFloat: finalDraft.itemFloat,
          declaredValue: finalDraft.declaredValue,
        );
      }
    }
    _drafts[conversationId] = finalDraft;

    for (final word in reply.split(' ')) {
      await Future<void>.delayed(const Duration(milliseconds: 40));
      yield '$word ';
    }
    messages.add(
      ConciergeMessage(
        id: 'cmsg-$conversationId-a$turn',
        conversationId: conversationId,
        role: ConciergeRole.assistant,
        text: reply,
        createdAt: serverNow(),
        structuredDraft: finalDraft,
        proposedAction: finalDraft.missingSlots.isEmpty
            ? ConciergeProposedAction.showPublishCard
            : ConciergeProposedAction.none,
      ),
    );
    _emit(conversationId);
    _idempotentResults[cacheKey] = (text, reply);
  }
}

/// Voice concierge placeholder. Gemini Live / LiveKit plug in behind
/// [VoiceConciergeAdapter] later. OD-17: per-language availability comes from
/// [_voiceLanguages] — the same fixture the mock bootstrap serves as
/// `AppBootstrap.voiceLanguages`. Unavailable languages (e.g. `pcm` until the
/// Pidgin voice gate passes) throw ERR_UNSUPPORTED_LANGUAGE so the UI falls
/// back to the text concierge.
class MockVoiceConciergeAdapter extends _MockRepo
    implements VoiceConciergeAdapter {
  MockVoiceConciergeAdapter(
    super.db,
    super.behavior, {
    Map<String, bool> voiceLanguages = kMockVoiceLanguages,
  }) : _voiceLanguages = voiceLanguages;

  final Map<String, bool> _voiceLanguages;

  @override
  Future<VoiceSession> startSession(
    String conversationId, {
    String language = 'en',
  }) async {
    await gate();
    if (!(_voiceLanguages[language] ?? false)) {
      throw const AppError(ErrorCodes.unsupportedLanguage);
    }
    return VoiceSession(
      sessionId: _mockId('voice'),
      conversationId: conversationId,
      language: language,
    );
  }

  @override
  Stream<VoiceEvent> events(String sessionId) async* {
    await gate();
    yield const VoiceEvent(
      kind: VoiceEventKind.sessionState,
      state: VoiceSessionState.connecting,
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    yield const VoiceEvent(
      kind: VoiceEventKind.sessionState,
      state: VoiceSessionState.listening,
    );
  }

  /// No-op until the vendor SDK lands.
  @override
  Future<void> sendAudio(String sessionId, List<int> audioChunk) => gate();

  @override
  Future<void> endSession(String sessionId) => gate();
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
      sessionId: _mockId('liveness'),
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
  Future<VerificationSession> giveBiometricConsent({
    required String idempotencyKey,
  }) async {
    await gate();
    return idempotent('giveBiometricConsent', idempotencyKey, () async {
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
    });
  }

  @override
  Future<VerificationSession> startFacialVerification({
    required String idempotencyKey,
  }) async {
    await gate();
    return idempotent('startFacialVerification', idempotencyKey, () async {
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
    });
  }

  @override
  Future<VerificationSession> submitIdLookup(
    String sessionId,
    String idType,
    String idNumber, {
    required String idempotencyKey,
  }) async {
    await gate();
    return idempotent('submitIdLookup:$sessionId', idempotencyKey, () async {
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
    }, argsHash: '$idType|$idNumber');
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
    ProviderOnboardingInput input, {
    required String idempotencyKey,
  }) async {
    await gate();
    return idempotent(
      'saveOnboarding',
      idempotencyKey,
      () async {
        final profile = _profile();
        final updated = profile.copyWith(
          kind: input.kind,
          serviceCategoryIds: input.serviceCategoryIds,
          serviceAreaIds: input.serviceAreaIds,
          vehicleType: input.vehicleType,
        );
        _store(updated);
        return updated;
      },
      argsHash:
          '${input.kind}|${input.serviceCategoryIds.join(',')}'
          '|${input.serviceAreaIds.join(',')}|${input.vehicleType}',
    );
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
  Future<ProviderKycProfile> submitStep(
    KycStepKind kind,
    Object input, {
    required String idempotencyKey,
  }) async {
    await gate();
    return idempotent('submitStep:$kind', idempotencyKey, () async {
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
    }, argsHash: '$input');
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
  Future<ProviderKycProfile> submitForReview({
    required String idempotencyKey,
  }) async {
    await gate();
    return idempotent('submitForReview', idempotencyKey, () async {
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
    });
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

/// ---------------------------------------------------------------------------
/// M5: disputes, support, promos, settings
/// ---------------------------------------------------------------------------

class MockDisputeRepository extends _MockRepo implements DisputeRepository {
  MockDisputeRepository(super.db, super.behavior);

  /// States in which a party can still open a dispute (payment held or the
  /// job is being executed / just completed).
  static const Set<JobStatus> _disputable = <JobStatus>{
    JobStatus.paidHeld,
    JobStatus.assigned,
    JobStatus.enRoute,
    JobStatus.arrived,
    JobStatus.inProgress,
    JobStatus.completedByProvider,
    JobStatus.confirmed,
  };

  JobRequest _participantJob(String jobId) {
    final user = currentUser;
    final job = db.requests[jobId];
    if (job == null) throw const AppError(ErrorCodes.unknown);
    if (job.customerId != user.id && job.providerId != user.id) {
      throw const AppError(ErrorCodes.permissionDenied);
    }
    return job;
  }

  @override
  Future<List<Dispute>> getMyDisputes() async {
    await gate();
    final user = currentUser;
    final mine =
        db.disputes.values.where((Dispute d) {
            final job = db.requests[d.jobId];
            return d.openedBy == user.id ||
                job?.customerId == user.id ||
                job?.providerId == user.id;
          }).toList()
          ..sort((Dispute a, Dispute b) => b.createdAt.compareTo(a.createdAt));
    return mine;
  }

  @override
  Stream<Dispute?> watchDispute(String jobId) {
    late StreamController<Dispute?> controller;
    StreamSubscription<Dispute>? sub;
    controller = StreamController<Dispute?>(
      onListen: () {
        controller.add(db.disputes[jobId]);
        sub = db.disputeEvents.stream
            .where((Dispute d) => d.jobId == jobId)
            .listen(controller.add);
      },
      onCancel: () {
        unawaited(sub?.cancel());
        unawaited(controller.close());
      },
    );
    return controller.stream;
  }

  @override
  Future<Dispute> openDispute({
    required String jobId,
    required String reasonKey,
    required String idempotencyKey,
    String? details,
    List<String> evidencePaths = const <String>[],
  }) async {
    await gate();
    return idempotent('openDispute:$jobId', idempotencyKey, () async {
      final user = currentUser;
      final job = _participantJob(jobId);
      // One dispute per job: re-opening returns the existing one.
      final existing = db.disputes[jobId];
      if (existing != null) return existing;
      if (!_disputable.contains(job.status)) {
        throw const AppError(ErrorCodes.invalidState);
      }
      final dispute = Dispute(
        id: _mockId('disp'),
        jobId: jobId,
        openedBy: user.id,
        reasonKey: reasonKey,
        status: DisputeStatus.open,
        createdAt: serverNow(),
        details: details,
        evidencePaths: evidencePaths.isEmpty ? null : evidencePaths,
        slaDeadline: serverNow().add(const Duration(hours: 24)),
      );
      _store(dispute);
      final disputed = job.copyWith(status: JobStatus.disputed);
      db.requests[jobId] = disputed;
      db.jobEvents.add(disputed);
      _scheduleResolution(dispute.id);
      return dispute;
    }, argsHash: '$reasonKey|${details ?? ''}|${evidencePaths.join(',')}');
  }

  /// The mock "ops team": after `behavior.disputeResolveDelay` the dispute
  /// resolves with a 50% partial refund — job → REFUNDED, payment →
  /// PARTIALLY_REFUNDED. All amounts are server-decided.
  void _scheduleResolution(String disputeId) {
    Timer(behavior.disputeResolveDelay, () {
      final entry = db.disputes.entries.where(
        (MapEntry<String, Dispute> e) => e.value.id == disputeId,
      );
      if (entry.isEmpty) return;
      final current = entry.first.value;
      if (current.status == DisputeStatus.resolved) return;
      final job = db.requests[current.jobId];
      final agreed = job?.agreedPrice;
      final refund = agreed == null
          ? null
          : Money(agreed.minorUnits ~/ 2, agreed.currencyCode);
      final resolved = current.copyWith(
        status: DisputeStatus.resolved,
        resolutionNoteKey: 'disputeResolvedPartialRefund',
        refundAmount: refund,
      );
      _store(resolved);
      if (job != null) {
        final refunded = job.copyWith(status: JobStatus.refunded);
        db.requests[job.id] = refunded;
        db.jobEvents.add(refunded);
      }
      final paymentId = db.paymentByJob[current.jobId];
      final payment = paymentId == null ? null : db.payments[paymentId];
      if (payment != null && payment.status == PaymentStatus.held) {
        final refunded = payment.copyWith(
          status: PaymentStatus.partiallyRefunded,
        );
        db.payments[payment.id] = refunded;
        db.paymentEvents.add(refunded);
      }
    });
  }

  void _store(Dispute dispute) {
    db.disputes[dispute.jobId] = dispute;
    db.disputeEvents.add(dispute);
  }
}

class MockSupportRepository extends _MockRepo implements SupportRepository {
  MockSupportRepository(super.db, super.behavior);

  List<SupportTicket> _sorted() {
    final list = db.tickets.values.toList()
      ..sort(
        (SupportTicket a, SupportTicket b) =>
            b.createdAt.compareTo(a.createdAt),
      );
    return list;
  }

  @override
  Future<List<SupportTicket>> getTickets() async {
    await gate();
    return _sorted();
  }

  @override
  Stream<List<SupportTicket>> watchTickets() {
    late StreamController<List<SupportTicket>> controller;
    StreamSubscription<SupportTicket>? sub;
    controller = StreamController<List<SupportTicket>>(
      onListen: () {
        controller.add(_sorted());
        sub = db.supportEvents.stream.listen(
          (SupportTicket _) => controller.add(_sorted()),
        );
      },
      onCancel: () {
        unawaited(sub?.cancel());
        unawaited(controller.close());
      },
    );
    return controller.stream;
  }

  @override
  Future<SupportTicket> createTicket({
    required String subject,
    required String body,
    required String idempotencyKey,
  }) async {
    await gate();
    return idempotent('createTicket', idempotencyKey, () async {
      final now = serverNow();
      final ticket = SupportTicket(
        id: _mockId('ticket'),
        subject: subject,
        status: SupportTicketStatus.open,
        createdAt: now,
        messages: <SupportMessage>[
          SupportMessage(
            id: 'tmsg-${now.microsecondsSinceEpoch}',
            body: body,
            fromUser: true,
            createdAt: now,
          ),
        ],
      );
      db.tickets[ticket.id] = ticket;
      db.supportEvents.add(ticket);
      _scheduleTriageReply(ticket.id);
      return ticket;
    }, argsHash: '$subject|$body');
  }

  @override
  Future<SupportTicket> replyToTicket(
    String ticketId,
    String body, {
    required String idempotencyKey,
  }) async {
    await gate();
    return idempotent('replyTicket:$ticketId', idempotencyKey, () async {
      final ticket = db.tickets[ticketId];
      if (ticket == null) throw const AppError(ErrorCodes.unknown);
      final now = serverNow();
      final updated = ticket.copyWith(
        status: SupportTicketStatus.awaitingUser,
        messages: <SupportMessage>[
          ...ticket.messages,
          SupportMessage(
            id: 'tmsg-${now.microsecondsSinceEpoch}',
            body: body,
            fromUser: true,
            createdAt: now,
          ),
        ],
      );
      db.tickets[ticketId] = updated;
      db.supportEvents.add(updated);
      _scheduleTriageReply(ticketId);
      return updated;
    }, argsHash: body);
  }

  /// AI first-line triage answers every user message after
  /// `behavior.supportTriageDelay` (spec: help center AI triage).
  void _scheduleTriageReply(String ticketId) {
    Timer(behavior.supportTriageDelay, () {
      final ticket = db.tickets[ticketId];
      if (ticket == null) return;
      final now = serverNow();
      final updated = ticket.copyWith(
        status: SupportTicketStatus.awaitingUser,
        messages: <SupportMessage>[
          ...ticket.messages,
          SupportMessage(
            id: 'tmsg-${now.microsecondsSinceEpoch}-ai',
            body:
                'Thanks — I have logged this and shared the relevant details '
                'with our support team. A human agent will follow up if '
                'anything else is needed.',
            fromUser: false,
            aiTriage: true,
            createdAt: now,
          ),
        ],
      );
      db.tickets[ticketId] = updated;
      db.supportEvents.add(updated);
    });
  }
}

class MockPromoRepository extends _MockRepo implements PromoRepository {
  MockPromoRepository(super.db, super.behavior);

  @override
  Future<List<Promo>> getPromos() async {
    await gate();
    final list = db.promos.values.toList()
      ..sort((Promo a, Promo b) => b.expiresAt.compareTo(a.expiresAt));
    return list;
  }

  @override
  Future<Promo> redeemPromo(
    String code, {
    required String idempotencyKey,
  }) async {
    await gate();
    final normalized = code.trim().toUpperCase();
    return idempotent('redeemPromo', idempotencyKey, () async {
      final promo = db.promos[normalized];
      // Validity is a server decision: unknown, expired or already-redeemed
      // codes all fail with the same error code.
      if (promo == null ||
          promo.redeemed ||
          promo.expiresAt.isBefore(serverNow())) {
        throw const AppError(ErrorCodes.promoInvalid);
      }
      final redeemed = promo.copyWith(redeemed: true);
      db.promos[normalized] = redeemed;
      return redeemed;
    }, argsHash: normalized);
  }
}

class MockSettingsRepository extends _MockRepo implements SettingsRepository {
  MockSettingsRepository(super.db, super.behavior);

  static const int maxTrustedContacts = 5;

  static const NotificationPreferences _defaultPrefs = NotificationPreferences(
    push: true,
    sms: true,
    email: true,
    marketing: false,
  );

  @override
  Future<NotificationPreferences> getNotificationPreferences() async {
    await gate();
    return db.notificationPrefs[behavior.currentUserId] ?? _defaultPrefs;
  }

  @override
  Future<NotificationPreferences> updateNotificationPreferences(
    NotificationPreferences preferences, {
    required String idempotencyKey,
  }) async {
    await gate();
    return idempotent('updateNotifPrefs', idempotencyKey, () async {
      db.notificationPrefs[behavior.currentUserId] = preferences;
      return preferences;
    }, argsHash: preferences.toString());
  }

  @override
  Future<List<TrustedContact>> getTrustedContacts() async {
    await gate();
    return List<TrustedContact>.unmodifiable(
      db.trustedContacts[behavior.currentUserId] ?? const <TrustedContact>[],
    );
  }

  @override
  Future<TrustedContact> addTrustedContact({
    required String name,
    required String phoneE164,
    required String idempotencyKey,
  }) async {
    await gate();
    return idempotent('addTrustedContact', idempotencyKey, () async {
      final list = db.trustedContacts.putIfAbsent(
        behavior.currentUserId,
        () => <TrustedContact>[],
      );
      if (list.length >= maxTrustedContacts) {
        throw const AppError(ErrorCodes.invalidState);
      }
      final contact = TrustedContact(
        id: _mockId('tc'),
        name: name,
        phoneE164: phoneE164,
      );
      list.add(contact);
      return contact;
    }, argsHash: '$name|$phoneE164');
  }

  @override
  Future<void> removeTrustedContact(
    String contactId, {
    required String idempotencyKey,
  }) async {
    await gate();
    // `idempotent` stores non-null results, so the void removal returns a
    // sentinel bool that is discarded.
    await idempotent(
      'removeTrustedContact:$contactId',
      idempotencyKey,
      () async {
        db.trustedContacts[behavior.currentUserId]?.removeWhere(
          (TrustedContact c) => c.id == contactId,
        );
        return true;
      },
    );
  }

  @override
  Future<DateTime> requestAccountDeletion({
    required String idempotencyKey,
  }) async {
    await gate();
    // Store-readiness grace period: deletion is scheduled 30 days out;
    // signing back in before then cancels it.
    return idempotent(
      'requestAccountDeletion',
      idempotencyKey,
      () async => serverNow().add(const Duration(days: 30)),
    );
  }

  @override
  Future<String> requestDataExport({required String idempotencyKey}) async {
    await gate();
    return idempotent(
      'requestDataExport',
      idempotencyKey,
      () async => _mockId('export'),
    );
  }
}

/// ---------------------------------------------------------------------------
/// M6: provider tools + business console
/// ---------------------------------------------------------------------------

class MockProviderToolsRepository extends _MockRepo
    implements ProviderToolsRepository {
  MockProviderToolsRepository(super.db, super.behavior);

  String get _providerId => currentUser.id;

  @override
  Future<List<AvailabilitySlot>> getAvailability() async {
    await gate();
    return List<AvailabilitySlot>.unmodifiable(
      db.availability[_providerId] ?? const <AvailabilitySlot>[],
    );
  }

  @override
  Future<List<AvailabilitySlot>> setAvailability(
    List<AvailabilitySlot> slots, {
    required String idempotencyKey,
  }) async {
    await gate();
    return idempotent('setAvailability', idempotencyKey, () async {
      for (final slot in slots) {
        if (slot.dayOfWeek < 1 ||
            slot.dayOfWeek > 7 ||
            slot.startMinutes < 0 ||
            slot.endMinutes > 24 * 60 ||
            slot.startMinutes >= slot.endMinutes) {
          throw const AppError(ErrorCodes.invalidState);
        }
      }
      db.availability[_providerId] = List<AvailabilitySlot>.of(slots);
      return List<AvailabilitySlot>.unmodifiable(slots);
    }, argsHash: slots.toString());
  }

  @override
  Future<EarningsGoal?> getEarningsGoal() async {
    await gate();
    return db.earningsGoals[_providerId];
  }

  @override
  Future<EarningsGoal> setEarningsGoal(
    Money target,
    GoalPeriod period, {
    required String idempotencyKey,
  }) async {
    await gate();
    return idempotent('setEarningsGoal', idempotencyKey, () async {
      if (target.minorUnits <= 0) {
        throw const AppError(ErrorCodes.invalidState);
      }
      // Progress stays server-computed: keep whatever the "server" last
      // computed for this provider (seeded fixture), zero for a fresh goal.
      final progress =
          db.earningsGoals[_providerId]?.progress ??
          Money(0, target.currencyCode);
      final goal = EarningsGoal(
        target: target,
        period: period,
        progress: progress,
      );
      db.earningsGoals[_providerId] = goal;
      return goal;
    }, argsHash: '${target.minorUnits} ${target.currencyCode} $period');
  }

  @override
  Future<List<DemandZone>> getDemandHeatmap() async {
    await gate();
    final zones = List<DemandZone>.of(
      db.demandZones,
    )..sort((DemandZone a, DemandZone b) => b.intensity.compareTo(a.intensity));
    return zones;
  }

  @override
  Future<ProviderInsights> getInsights() async {
    await gate();
    final profile = db.providers[_providerId];
    return ProviderInsights(
      acceptanceRate: 0.86,
      completionRate: 0.97,
      avgRating: profile?.rating ?? 0,
      fiveStarShare: 0.71,
      avgResponseTimeSeconds: profile?.avgResponseTimeSeconds ?? 0,
      periodDays: 30,
    );
  }

  /// Mock pricing for instant payout (server-side decision): 1.5% fee,
  /// capped at ₦2,000.
  InstantPayoutQuote _quote(Money amount) {
    final rawFee = (amount.minorUnits * 15) ~/ 1000;
    final feeMinor = rawFee > 200000 ? 200000 : rawFee;
    return InstantPayoutQuote(
      fee: Money(feeMinor, amount.currencyCode),
      net: Money(amount.minorUnits - feeMinor, amount.currencyCode),
      arrivesWithinMinutes: 15,
    );
  }

  @override
  Future<InstantPayoutQuote> quoteInstantPayout(Money amount) async {
    await gate();
    if (amount.minorUnits <= 0) {
      throw const AppError(ErrorCodes.invalidState);
    }
    return _quote(amount);
  }

  @override
  Future<WalletTransaction> requestInstantPayout(
    Money amount, {
    required String idempotencyKey,
  }) async {
    await gate();
    return idempotent('instantPayout', idempotencyKey, () async {
      final user = currentUser;
      if (user.providerVerification != VerificationStatus.verified) {
        throw const AppError(ErrorCodes.kycIncomplete);
      }
      final summary = db.wallets[user.id];
      final available = summary?.available ?? Money(0, amount.currencyCode);
      if (amount > available) {
        throw const AppError(ErrorCodes.insufficientBalance);
      }
      final quote = _quote(amount);
      // Debit the full amount; the fee never leaves the platform.
      db.wallets[user.id] =
          (summary ??
                  WalletSummary(
                    available: available,
                    pending: Money(0, amount.currencyCode),
                  ))
              .copyWith(
                available: Money(
                  available.minorUnits - amount.minorUnits,
                  amount.currencyCode,
                ),
              );
      final txn = WalletTransaction(
        id: _mockId('txn'),
        kind: WalletTransactionKind.payout,
        status: WalletTransactionStatus.completed,
        amount: quote.net,
        descriptionKey: 'txnInstantPayout',
        createdAt: serverNow(),
      );
      db.walletTransactions
          .putIfAbsent(user.id, () => <WalletTransaction>[])
          .add(txn);
      return txn;
    }, argsHash: '${amount.minorUnits} ${amount.currencyCode}');
  }
}

class MockOrganizationRepository extends _MockRepo
    implements OrganizationRepository {
  MockOrganizationRepository(super.db, super.behavior);

  /// The org the current user belongs to (any role), or null.
  Organization? _myOrg() {
    final userId = currentUser.id;
    for (final org in db.organizations.values) {
      final members = db.orgMembers[org.id] ?? const <OrgMember>[];
      if (members.any((OrgMember m) => m.userId == userId)) return org;
    }
    return null;
  }

  BusinessRole? _myRole(String orgId) {
    final userId = currentUser.id;
    for (final m in db.orgMembers[orgId] ?? const <OrgMember>[]) {
      if (m.userId == userId) return m.role;
    }
    return null;
  }

  Organization _requireOrg() {
    final org = _myOrg();
    if (org == null) throw const AppError(ErrorCodes.permissionDenied);
    return org;
  }

  /// Owner/dispatcher-only actions.
  void _requireManager(String orgId) {
    final role = _myRole(orgId);
    if (role != BusinessRole.owner && role != BusinessRole.dispatcher) {
      throw const AppError(ErrorCodes.permissionDenied);
    }
  }

  @override
  Future<Organization?> getMyOrganization() async {
    await gate();
    return _myOrg();
  }

  @override
  Future<List<OrgMember>> getMembers() async {
    await gate();
    final org = _requireOrg();
    final isOwner = _myRole(org.id) == BusinessRole.owner;
    final members = db.orgMembers[org.id] ?? const <OrgMember>[];
    // Per-worker earnings are Owner-visible only (spec).
    return <OrgMember>[
      for (final m in members) isOwner ? m : m.copyWith(earningsToDate: null),
    ];
  }

  @override
  Future<OrgMember> inviteMember({
    required String phoneE164,
    required BusinessRole role,
    required String idempotencyKey,
  }) async {
    await gate();
    return idempotent('orgInvite', idempotencyKey, () async {
      final org = _requireOrg();
      _requireManager(org.id);
      if (role == BusinessRole.owner) {
        throw const AppError(ErrorCodes.invalidState);
      }
      final members = db.orgMembers.putIfAbsent(org.id, () => <OrgMember>[]);
      final id = 'user-invited-${phoneE164.replaceAll(RegExp('[^0-9]'), '')}';
      if (members.any((OrgMember m) => m.userId == id)) {
        throw const AppError(ErrorCodes.invalidState);
      }
      final member = OrgMember(
        userId: id,
        displayName: phoneE164, // name arrives once the invitee signs up
        role: role,
        verificationStatus: VerificationStatus.pending,
        jobsCompleted: 0,
        earningsToDate: const Money(0, 'NGN'),
      );
      members.add(member);
      db.organizations[org.id] = org.copyWith(memberCount: members.length);
      return member;
    }, argsHash: '$phoneE164|$role');
  }

  @override
  Future<void> removeMember(
    String userId, {
    required String idempotencyKey,
  }) async {
    await gate();
    await idempotent('orgRemoveMember:$userId', idempotencyKey, () async {
      final org = _requireOrg();
      _requireManager(org.id);
      if (userId == org.ownerId) {
        throw const AppError(ErrorCodes.invalidState);
      }
      final members = db.orgMembers[org.id] ?? <OrgMember>[];
      members.removeWhere((OrgMember m) => m.userId == userId);
      db.organizations[org.id] = org.copyWith(memberCount: members.length);
      return true;
    });
  }

  @override
  Future<List<JobRequest>> getAssignableJobs() async {
    await gate();
    _requireOrg();
    final orgProfileIds = db.providers.values
        .where((ProviderProfile p) => p.kind == ProviderKind.business)
        .map((ProviderProfile p) => p.userId)
        .toSet();
    return db.requests.values
        .where(
          (JobRequest r) =>
              r.providerId != null &&
              orgProfileIds.contains(r.providerId) &&
              !db.orgAssignments.containsKey(r.id) &&
              (r.status == JobStatus.paidHeld ||
                  r.status == JobStatus.assigned),
        )
        .toList();
  }

  @override
  Future<JobRequest> assignJob({
    required String jobId,
    required String workerId,
    required String idempotencyKey,
  }) async {
    await gate();
    return idempotent('orgAssignJob:$jobId', idempotencyKey, () async {
      final org = _requireOrg();
      _requireManager(org.id);
      final job = db.requests[jobId];
      if (job == null) throw const AppError(ErrorCodes.unknown);
      final worker = (db.orgMembers[org.id] ?? const <OrgMember>[])
          .where((OrgMember m) => m.userId == workerId)
          .firstOrNull;
      if (worker == null ||
          worker.role != BusinessRole.worker ||
          worker.verificationStatus != VerificationStatus.verified) {
        throw const AppError(ErrorCodes.permissionDenied);
      }
      final assignable = (await getAssignableJobs()).any(
        (JobRequest r) => r.id == jobId,
      );
      if (!assignable) throw const AppError(ErrorCodes.invalidState);
      db.orgAssignments[jobId] = workerId;
      final updated = job.copyWith(status: JobStatus.assigned);
      db.requests[jobId] = updated;
      db.jobEvents.add(updated);
      return updated;
    }, argsHash: workerId);
  }

  @override
  Future<List<Vehicle>> getVehicles() async {
    await gate();
    final org = _requireOrg();
    return List<Vehicle>.unmodifiable(db.vehicles[org.id] ?? const <Vehicle>[]);
  }

  @override
  Future<Vehicle> upsertVehicle(
    Vehicle vehicle, {
    required String idempotencyKey,
  }) async {
    await gate();
    return idempotent(
      'orgUpsertVehicle:${vehicle.id}',
      idempotencyKey,
      () async {
        final org = _requireOrg();
        _requireManager(org.id);
        final list = db.vehicles.putIfAbsent(org.id, () => <Vehicle>[]);
        final stored = vehicle.copyWith(organizationId: org.id);
        final idx = list.indexWhere((Vehicle v) => v.id == vehicle.id);
        if (idx >= 0) {
          list[idx] = stored;
        } else {
          list.add(stored);
        }
        db.organizations[org.id] = org.copyWith(
          activeVehicleCount: list.length,
        );
        return stored;
      },
      argsHash: vehicle.toString(),
    );
  }

  @override
  Future<Vehicle> assignVehicle(
    String vehicleId,
    String? workerId, {
    required String idempotencyKey,
  }) async {
    await gate();
    return idempotent('orgAssignVehicle:$vehicleId', idempotencyKey, () async {
      final org = _requireOrg();
      _requireManager(org.id);
      final list = db.vehicles[org.id] ?? <Vehicle>[];
      final idx = list.indexWhere((Vehicle v) => v.id == vehicleId);
      if (idx < 0) throw const AppError(ErrorCodes.unknown);
      if (workerId != null) {
        final worker = (db.orgMembers[org.id] ?? const <OrgMember>[])
            .where((OrgMember m) => m.userId == workerId)
            .firstOrNull;
        if (worker == null || worker.role != BusinessRole.worker) {
          throw const AppError(ErrorCodes.permissionDenied);
        }
      }
      final updated = list[idx].copyWith(assignedWorkerId: workerId);
      list[idx] = updated;
      return updated;
    }, argsHash: workerId ?? '');
  }
}
