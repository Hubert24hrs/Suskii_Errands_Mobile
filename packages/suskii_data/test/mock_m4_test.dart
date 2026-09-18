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

  Matcher expectCode(String code) =>
      isA<AppError>().having((AppError e) => e.code, 'code', code);

  /// Awaits a closure expected to throw (every throw-expectation is awaited so
  /// later statements — persona switches, endCall — cannot race the gated
  /// mock call).
  Future<void> expectThrows(Future<Object?> Function() fn, String code) =>
      expectLater(fn, throwsA(expectCode(code)));

  /// Puts req-1 into AGREED with a server-style price.
  JobRequest agreeReq1() {
    final agreed = db.requests['req-1']!.copyWith(
      status: JobStatus.agreed,
      agreedPrice: const Money(500000, 'NGN'),
      providerId: 'provider-musa',
    );
    db.requests['req-1'] = agreed;
    return agreed;
  }

  group('payments (M4)', () {
    test('initialize requires a verified customer', () async {
      behavior.currentUserId = 'user-chidi';
      agreeReq1();
      final repo = MockPaymentRepository(db, behavior);
      await expectThrows(
        () => repo.initializePayment(
          jobId: 'req-1',
          method: PaymentMethod.card,
          idempotencyKey: newIdempotencyKey(),
        ),
        ErrorCodes.verificationRequired,
      );
    });

    test('initialize requires an AGREED/PAYMENT_PENDING job', () async {
      final repo = MockPaymentRepository(db, behavior);
      await expectThrows(
        () => repo.initializePayment(
          jobId: 'req-1', // negotiating
          method: PaymentMethod.card,
          idempotencyKey: newIdempotencyKey(),
        ),
        ErrorCodes.invalidState,
      );
    });

    test('only the customer pays', () async {
      behavior.currentUserId = 'user-kofi';
      agreeReq1();
      final repo = MockPaymentRepository(db, behavior);
      await expectThrows(
        () => repo.initializePayment(
          jobId: 'req-1',
          method: PaymentMethod.card,
          idempotencyKey: newIdempotencyKey(),
        ),
        ErrorCodes.permissionDenied,
      );
    });

    test(
      'initialize → pending → webhook confirm flips payment HELD and job PAID_HELD',
      () async {
        behavior.paymentConfirmDelay = const Duration(milliseconds: 50);
        agreeReq1();
        final repo = MockPaymentRepository(db, behavior);
        final session = await repo.initializePayment(
          jobId: 'req-1',
          method: PaymentMethod.card,
          idempotencyKey: newIdempotencyKey(),
        );
        expect(session.payment.status, PaymentStatus.pending);
        expect(db.requests['req-1']!.status, JobStatus.paymentPending);
        expect(session.payment.expiresAt, isNotNull);

        await Future<void>.delayed(const Duration(milliseconds: 200));
        final payment = await repo.getPaymentForJob('req-1');
        expect(payment!.status, PaymentStatus.held);
        expect(payment.paidAt, isNotNull);
        expect(db.requests['req-1']!.status, JobStatus.paidHeld);
      },
    );

    test('watchPaymentForJob streams pending → held', () async {
      behavior.paymentConfirmDelay = const Duration(milliseconds: 50);
      agreeReq1();
      final repo = MockPaymentRepository(db, behavior);
      final statuses = repo
          .watchPaymentForJob('req-1')
          .take(3)
          .map((Payment? p) => p?.status)
          .toList();
      await repo.initializePayment(
        jobId: 'req-1',
        method: PaymentMethod.mobileMoney,
        idempotencyKey: newIdempotencyKey(),
      );
      expect(
        await statuses,
        containsAllInOrder(<PaymentStatus>[
          PaymentStatus.pending,
          PaymentStatus.held,
        ]),
      );
    });

    test(
      'gateway decline fails the payment and returns the job to AGREED',
      () async {
        behavior.paymentConfirmDelay = const Duration(milliseconds: 50);
        behavior.failNextPayment = true;
        agreeReq1();
        final repo = MockPaymentRepository(db, behavior);
        await repo.initializePayment(
          jobId: 'req-1',
          method: PaymentMethod.card,
          idempotencyKey: newIdempotencyKey(),
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
        final payment = await repo.getPaymentForJob('req-1');
        expect(payment!.status, PaymentStatus.failed);
        expect(payment.failureReasonKey, isNotNull);
        expect(db.requests['req-1']!.status, JobStatus.agreed);
      },
    );

    test('same key replays; same key + different method is refused', () async {
      behavior.paymentConfirmDelay = const Duration(minutes: 1);
      agreeReq1();
      final repo = MockPaymentRepository(db, behavior);
      final key = newIdempotencyKey();
      final first = await repo.initializePayment(
        jobId: 'req-1',
        method: PaymentMethod.card,
        idempotencyKey: key,
      );
      final replay = await repo.initializePayment(
        jobId: 'req-1',
        method: PaymentMethod.card,
        idempotencyKey: key,
      );
      expect(replay.payment.id, first.payment.id);
      expect(db.payments.length, 1);
      await expectThrows(
        () => repo.initializePayment(
          jobId: 'req-1',
          method: PaymentMethod.ussd,
          idempotencyKey: key,
        ),
        ErrorCodes.idempotencyKeyReused,
      );
    });

    test('a fresh key within the TTL returns the in-flight payment', () async {
      behavior.paymentConfirmDelay = const Duration(minutes: 1);
      agreeReq1();
      final repo = MockPaymentRepository(db, behavior);
      final first = await repo.initializePayment(
        jobId: 'req-1',
        method: PaymentMethod.card,
        idempotencyKey: newIdempotencyKey(),
      );
      final second = await repo.initializePayment(
        jobId: 'req-1',
        method: PaymentMethod.card,
        idempotencyKey: newIdempotencyKey(),
      );
      expect(second.payment.id, first.payment.id);
      expect(db.payments.length, 1);
    });

    test('bank transfer returns the reference; card returns none', () async {
      behavior.paymentConfirmDelay = const Duration(minutes: 1);
      agreeReq1();
      final repo = MockPaymentRepository(db, behavior);
      final transfer = await repo.initializePayment(
        jobId: 'req-1',
        method: PaymentMethod.bankTransfer,
        idempotencyKey: newIdempotencyKey(),
      );
      expect(transfer.reference, isNotNull);
      expect(transfer.ussdCode, isNull);
    });
  });

  group('ratings (M4)', () {
    test('customer rates a closed job; stored rating is readable', () async {
      final repo = MockRatingRepository(db, behavior);
      expect(await repo.getMyRatingForJob('req-4'), isNull);
      final rating = await repo.submitRating(
        jobId: 'req-4',
        stars: 5,
        tagKeys: const ['ratingTagPunctual'],
        idempotencyKey: newIdempotencyKey(),
      );
      expect(rating.rateeId, 'provider-ngozi');
      expect((await repo.getMyRatingForJob('req-4'))!.stars, 5);
    });

    test('one rating per party per job', () async {
      final repo = MockRatingRepository(db, behavior);
      await repo.submitRating(
        jobId: 'req-4',
        stars: 4,
        idempotencyKey: newIdempotencyKey(),
      );
      await expectThrows(
        () => repo.submitRating(
          jobId: 'req-4',
          stars: 3,
          idempotencyKey: newIdempotencyKey(),
        ),
        ErrorCodes.invalidState,
      );
    });

    test('non-participants and non-rateable states are refused', () async {
      behavior.currentUserId = 'user-kofi';
      final repo = MockRatingRepository(db, behavior);
      await expectThrows(
        () => repo.submitRating(
          jobId: 'req-4',
          stars: 5,
          idempotencyKey: newIdempotencyKey(),
        ),
        ErrorCodes.permissionDenied,
      );
      behavior.currentUserId = 'user-ada';
      await expectThrows(
        () => repo.submitRating(
          jobId: 'req-1', // negotiating
          stars: 5,
          idempotencyKey: newIdempotencyKey(),
        ),
        ErrorCodes.invalidState,
      );
      await expectThrows(
        () => repo.submitRating(
          jobId: 'req-4',
          stars: 6,
          idempotencyKey: newIdempotencyKey(),
        ),
        ErrorCodes.invalidState,
      );
    });
  });

  group('safety (M4)', () {
    test('SOS on an active job creates one alert and streams it', () async {
      final repo = MockSafetyRepository(db, behavior);
      final alerts = repo.watchActiveSos('req-2').take(2).toList();
      final alert = await repo.triggerSos(
        jobId: 'req-2', // enRoute
        idempotencyKey: newIdempotencyKey(),
        location: const GeoPoint(latitude: 6.43, longitude: 3.44),
      );
      expect(alert.status, SosStatus.active);
      expect(alert.trustedContactsNotified, greaterThan(0));
      // A second trigger while active returns the same alert.
      final again = await repo.triggerSos(
        jobId: 'req-2',
        idempotencyKey: newIdempotencyKey(),
      );
      expect(again.id, alert.id);
      expect(await alerts, contains(isNotNull));
    });

    test('SOS requires an active job and a participant', () async {
      final repo = MockSafetyRepository(db, behavior);
      await expectThrows(
        () => repo.triggerSos(
          jobId: 'req-5', // draft
          idempotencyKey: newIdempotencyKey(),
        ),
        ErrorCodes.invalidState,
      );
      behavior.currentUserId = 'user-kofi';
      await expectThrows(
        () => repo.triggerSos(
          jobId: 'req-2',
          idempotencyKey: newIdempotencyKey(),
        ),
        ErrorCodes.permissionDenied,
      );
    });

    test('trip share link is expiring and participant-only', () async {
      final repo = MockSafetyRepository(db, behavior);
      final share = await repo.createTripShareLink(
        'req-2',
        idempotencyKey: newIdempotencyKey(),
      );
      expect(share.url, contains('req-2'));
      expect(share.expiresAt.isAfter(DateTime.now()), isTrue);
      await expectThrows(
        () => repo.createTripShareLink(
          'req-5',
          idempotencyKey: newIdempotencyKey(),
        ),
        ErrorCodes.invalidState,
      );
    });
  });

  group('calls (M4)', () {
    test('startCall connects, rings, then goes active', () async {
      final adapter = MockCallAdapter(db, behavior);
      final session = await adapter.startCall(
        'req-2', // enRoute
        idempotencyKey: newIdempotencyKey(),
      );
      await expectLater(
        adapter.events(session.sessionId).take(3),
        emitsInOrder(<Matcher>[
          isA<CallEvent>().having(
            (CallEvent e) => e.state,
            'state',
            CallState.connecting,
          ),
          isA<CallEvent>().having(
            (CallEvent e) => e.state,
            'state',
            CallState.ringing,
          ),
          isA<CallEvent>().having(
            (CallEvent e) => e.state,
            'state',
            CallState.active,
          ),
        ]),
      );
    });

    test('one active call per job; ending releases the job', () async {
      final adapter = MockCallAdapter(db, behavior);
      final session = await adapter.startCall(
        'req-2',
        idempotencyKey: newIdempotencyKey(),
      );
      await expectThrows(
        () => adapter.startCall('req-2', idempotencyKey: newIdempotencyKey()),
        ErrorCodes.callInProgress,
      );
      await adapter.endCall(session.sessionId);
      final second = await adapter.startCall(
        'req-2',
        idempotencyKey: newIdempotencyKey(),
      );
      expect(second.sessionId, isNot(session.sessionId));
    });

    test('calls need a participant and a callable job state', () async {
      final adapter = MockCallAdapter(db, behavior);
      await expectThrows(
        () => adapter.startCall('req-5', idempotencyKey: newIdempotencyKey()),
        ErrorCodes.permissionDenied,
      );
      behavior.currentUserId = 'user-kofi';
      await expectThrows(
        () => adapter.startCall('req-2', idempotencyKey: newIdempotencyKey()),
        ErrorCodes.permissionDenied,
      );
    });
  });
}
