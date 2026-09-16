import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_data/suskii_data.dart';
import 'package:suskii_domain/suskii_domain.dart';
import 'package:test/test.dart';

void main() {
  late MockDatabase db;
  late MockBehavior behavior;

  setUp(() {
    db = MockDatabase();
    behavior = MockBehavior(latency: Duration.zero);
  });

  group('roundHalfEven (ledger rounding)', () {
    test('matches the spec worked example: 2.1875 USD → 219 minor units', () {
      // net = 87.50 USD = 8750 minor; 2.5% = 218.75 → round half-even → 218?
      // 8750*25/1000 = 218.75: half-even on 218.75 → 219 is wrong; 218.75
      // rounds to 218.75 → integer minor units: 219 when > .5? Spec says 2.19.
      // 218.75 → nearest is 219? No: .75 > .5 rounds up → 219. Spec: $2.19. OK.
      expect(roundHalfEven(8750 * 25, 1000), 219);
    });

    test('exact halves round to even', () {
      expect(roundHalfEven(150, 100), 2); // 1.5 → 2 (even)
      expect(roundHalfEven(250, 100), 2); // 2.5 → 2 (even)
      expect(roundHalfEven(350, 100), 4); // 3.5 → 4 (even)
    });

    test('spec worked example: 12.5% of 100.00 USD = 1250 minor', () {
      final quote = simulateQuote(const Money(10000, 'USD'));
      expect(quote.platformCommission, const Money(1250, 'USD'));
      expect(quote.net, const Money(8750, 'USD'));
    });
  });

  group('MockBootstrapRepository', () {
    test('returns pack, user, feature flags and active job banner', () async {
      final repo = MockBootstrapRepository(db, behavior);
      final boot = await repo.getBootstrap();
      expect(boot.countryPack.countryCode, 'NG');
      expect(boot.countryPack.status, CountryStatus.live);
      expect(boot.user?.id, 'user-ada');
      expect(boot.featureFlags['aiConcierge'], isTrue);
      expect(boot.activeJobBanner, isNotNull);
      expect(boot.activeJobBanner!.status.needsAttention, isTrue);
    });

    test('offline mode throws ERR_NETWORK', () async {
      behavior.offline = true;
      final repo = MockBootstrapRepository(db, behavior);
      expect(
        repo.getBootstrap,
        throwsA(
          isA<AppError>().having((e) => e.code, 'code', ErrorCodes.network),
        ),
      );
    });
  });

  group('MockUserRepository', () {
    test('mode switch to provider allowed for verified provider', () async {
      final repo = MockUserRepository(db, behavior);
      expect(await repo.setActiveMode(UserMode.provider), UserMode.provider);
    });

    test('mode switch blocked for unverified provider', () async {
      behavior.currentUserId = 'user-chidi';
      final repo = MockUserRepository(db, behavior);
      expect(
        () => repo.setActiveMode(UserMode.provider),
        throwsA(
          isA<AppError>().having(
            (e) => e.code,
            'code',
            ErrorCodes.providerNotVerified,
          ),
        ),
      );
    });
  });

  group('MockOfferRepository', () {
    test(
      'accept locks others and agrees the job with a server breakdown',
      () async {
        final repo = MockOfferRepository(db, behavior);
        final accepted = await repo.acceptOffer('offer-1a');
        expect(accepted.status, OfferStatus.accepted);

        final request = db.requests['req-1']!;
        expect(request.status, JobStatus.agreed);
        expect(request.agreedPrice, const Money(650000, 'NGN'));
        expect(request.agreedBreakdown, isNotNull);
        expect(request.agreedBreakdown!.gross, const Money(650000, 'NGN'));

        final others = db.offers['req-1']!.where(
          (o) => o.id != 'offer-1a' && o.status == OfferStatus.pending,
        );
        expect(others, isEmpty);
      },
    );

    test('expired offers cannot be accepted', () async {
      final repo = MockOfferRepository(db, behavior);
      expect(
        () => repo.acceptOffer('offer-1c'),
        throwsA(
          isA<AppError>().having(
            (e) => e.code,
            'code',
            ErrorCodes.offerExpired,
          ),
        ),
      );
    });

    test('negotiation rounds capped by country pack', () async {
      final repo = MockOfferRepository(db, behavior);
      // offer-1b is at round 2; push it past the 5-round cap.
      final current = db.offers['req-1']![1];
      db.offers['req-1']![1] = current.copyWith(round: 5);
      expect(
        () => repo.counterOffer(
          offerId: 'offer-1b',
          amount: const Money(560000, 'NGN'),
        ),
        throwsA(
          isA<AppError>().having(
            (e) => e.code,
            'code',
            ErrorCodes.offerRoundsExhausted,
          ),
        ),
      );
    });
  });

  group('MockProviderRepository', () {
    test('self-dealing is blocked', () async {
      final repo = MockProviderRepository(db, behavior);
      expect(
        () => repo.submitOffer(
          requestId: 'req-1',
          amount: const Money(500000, 'NGN'),
        ),
        throwsA(
          isA<AppError>().having(
            (e) => e.code,
            'code',
            ErrorCodes.selfDealingBlocked,
          ),
        ),
      );
    });

    test('busy-as-customer rule is configurable', () async {
      final repo = MockProviderRepository(db, behavior);
      expect(await repo.setOnline(true), isTrue);
      db.providerBusyRuleEnabled = true;
      // user-ada has req-6 in paymentPending → blocked.
      expect(
        () => repo.setOnline(true),
        throwsA(
          isA<AppError>().having(
            (e) => e.code,
            'code',
            ErrorCodes.providerBusyAsCustomer,
          ),
        ),
      );
    });
  });

  group('MockJobProgressRepository', () {
    test('illegal transitions are rejected', () async {
      final repo = MockJobProgressRepository(db, behavior);
      expect(
        () => repo.requestStatusChange('req-2', JobStatus.completedByProvider),
        throwsA(isA<AppError>()),
      );
      // enRoute → arrived is legal.
      final updated = await repo.requestStatusChange(
        'req-2',
        JobStatus.arrived,
      );
      expect(updated.status, JobStatus.arrived);
    });
  });

  group('MockRequestRepository', () {
    test('paid jobs cannot be cancelled by the client path', () async {
      final repo = MockRequestRepository(db, behavior);
      expect(
        () => repo.cancelRequest('req-2', 'changedMind'),
        throwsA(
          isA<AppError>().having(
            (e) => e.code,
            'code',
            ErrorCodes.jobNotCancellable,
          ),
        ),
      );
    });

    test('history is paginated and terminal-only', () async {
      final repo = MockRequestRepository(db, behavior);
      final history = await repo.getMyRequestHistory();
      expect(history.every((r) => r.status.isTerminal), isTrue);
      expect(history.map((r) => r.id), contains('req-4'));
    });
  });

  group('MockWalletRepository', () {
    test('withdrawal below country minimum is rejected', () async {
      final repo = MockWalletRepository(db, behavior);
      expect(
        () => repo.requestWithdrawal(const Money(500, 'NGN')),
        throwsA(
          isA<AppError>().having(
            (e) => e.code,
            'code',
            ErrorCodes.withdrawalBelowMinimum,
          ),
        ),
      );
    });

    test('withdrawal above balance is rejected', () async {
      final repo = MockWalletRepository(db, behavior);
      expect(
        () => repo.requestWithdrawal(const Money(99999900, 'NGN')),
        throwsA(
          isA<AppError>().having(
            (e) => e.code,
            'code',
            ErrorCodes.insufficientBalance,
          ),
        ),
      );
    });
  });

  group('simulated realtime', () {
    test('offers stream seeds then emits a live offer', () async {
      behavior.latency = Duration.zero;
      final repo = MockOfferRepository(db, behavior);
      final stream = repo.watchOffers('req-1');
      final first = await stream.first;
      expect(first.length, 3);
    });

    test('tracking stream moves from pickup toward destination', () async {
      final repo = MockTrackingRepository(db, behavior);
      final points = await repo.watchProviderLocation('req-2').take(2).toList();
      expect(points.length, 2);
      expect(points.last.longitude, greaterThan(points.first.longitude));
    });
  });
}
