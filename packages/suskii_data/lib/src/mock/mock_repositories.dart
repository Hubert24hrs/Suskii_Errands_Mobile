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

  Duration _offerTtl(String categoryId) =>
      behavior.offerTtlOverride ??
      Duration(
        seconds: db.categories
            .firstWhere(
              (ServiceCategory c) => c.id == categoryId,
              orElse: () => db.categories.last,
            )
            .offerTtlSeconds,
      );

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
                  expiresAt: serverNow().add(_offerTtl(current.categoryId)),
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
          expiresAt: serverNow().add(_offerTtl(categoryId)),
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
          final id = 'req-live-${DateTime.now().millisecondsSinceEpoch}';
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

  static const Map<JobStatus, Set<JobStatus>> _allowed =
      <JobStatus, Set<JobStatus>>{
        JobStatus.assigned: <JobStatus>{JobStatus.enRoute},
        JobStatus.enRoute: <JobStatus>{JobStatus.arrived},
        JobStatus.arrived: <JobStatus>{JobStatus.inProgress},
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
      final updated = request.copyWith(status: target);
      db.requests[jobId] = updated;
      db.jobEvents.add(updated);
      return updated;
    }, argsHash: '$target');
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

  final Map<String, int> _pinAttempts = <String, int>{};

  @override
  Future<bool> verifyHandoverPin(
    String jobId,
    String pin, {
    required String idempotencyKey,
  }) async {
    await gate();
    return idempotent('verifyHandoverPin:$jobId', idempotencyKey, () async {
      // Attempt counting mirrors verify_pin: a wrong PIN spends one
      // attempt; replaying the same intent key does not.
      if ((_pinAttempts[jobId] ?? 0) >= 5) {
        throw const AppError(ErrorCodes.permissionDenied);
      }
      final ok = pin == '4281';
      if (!ok) _pinAttempts[jobId] = (_pinAttempts[jobId] ?? 0) + 1;
      return ok;
    }, argsHash: pin);
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
    }, argsHash: '$type|${text ?? ''}|${mediaPath ?? ''}');
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
        id: 'txn-ref-${DateTime.now().millisecondsSinceEpoch}',
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
  Future<PriceBand> getPriceBand({
    required String categoryId,
    GeoPoint? near,
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
        id: 'conv-${DateTime.now().millisecondsSinceEpoch}',
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
      sessionId: 'voice-${DateTime.now().millisecondsSinceEpoch}',
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
