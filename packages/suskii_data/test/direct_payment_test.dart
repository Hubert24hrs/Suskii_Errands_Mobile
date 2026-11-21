import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_data/suskii_data.dart';
import 'package:suskii_domain/suskii_domain.dart';
import 'package:test/test.dart';

/// Direct payment (ADR-0025): the country pack's mode and sign-in methods,
/// the job's direct flag and goods, Confirm hire, and the goods receipt.
void main() {
  Matcher expectCode(String code) =>
      isA<AppError>().having((AppError e) => e.code, 'code', code);

  group('mappers', () {
    test('the country pack carries the payment mode and sign-in methods', () {
      final pack = countryPackFromBootstrap(<String, dynamic>{
        'code': 'NG',
        'status': 'live',
        'currency': <String, dynamic>{'code': 'NGN', 'exponent': 2},
        'client': <String, dynamic>{
          'payment_mode': 'direct',
          'sign_in_methods': <dynamic>['email', 'google'],
        },
      });
      expect(pack.paymentMode, PaymentMode.direct);
      expect(pack.paysDirectly, isTrue);
      expect(pack.offersSignIn('email'), isTrue);
      expect(pack.offersSignIn('phone'), isFalse);
    });

    test('without them a pack pays in the app and offers every sign-in', () {
      final pack = countryPackFromBootstrap(<String, dynamic>{
        'code': 'KE',
        'status': 'beta',
        'currency': <String, dynamic>{'code': 'KES', 'exponent': 2},
      });
      expect(pack.paymentMode, PaymentMode.inApp);
      expect(pack.offersSignIn('phone'), isTrue);
    });

    test('the job embed carries the direct flag and the goods', () {
      final request = jobRequestFromRow(<String, dynamic>{
        'id': 'r1',
        'customer_id': 'c1',
        'is_custom_category': false,
        'description': 'Buy a gas refill',
        'urgency': 'standard',
        'status': 'in_progress',
        'pickup_label': 'Opebi Road',
        'item_float_minor': 500000,
        'currency': 'NGN',
        'created_at': '2026-11-21T10:00:00Z',
        'service_categories': <String, dynamic>{'key': 'shopping'},
        'jobs': <String, dynamic>{
          'provider_id': 'p1',
          'agreed_amount_minor': 200000,
          'currency': 'NGN',
          'direct_payment': true,
          'goods_spent_minor': 325000,
        },
      });
      expect(request.directPayment, isTrue);
      expect(request.goodsSpent, const Money(325000, 'NGN'));
      expect(request.directAmountDue, const Money(525000, 'NGN'));
      expect(request.awaitsGoodsReceipt, isFalse);
    });
  });

  group('mock repository', () {
    late MockDatabase db;
    late MockBehavior behavior;
    late MockJobProgressRepository repo;
    late String customerId;
    late JobRequest agreed;

    setUp(() {
      db = MockDatabase();
      behavior = MockBehavior(latency: Duration.zero);
      repo = MockJobProgressRepository(db, behavior);
      customerId = behavior.currentUserId;
      final country = db.users[customerId]!.countryCode;
      db.countryPacks[country] = db.countryPacks[country]!.copyWith(
        paymentMode: PaymentMode.direct,
      );
      agreed = db.requests.values.first.copyWith(
        id: 'req-direct',
        customerId: customerId,
        status: JobStatus.agreed,
        agreedPrice: const Money(200000, 'NGN'),
        itemFloat: const Money(500000, 'NGN'),
        destination: null,
      );
      db.requests[agreed.id] = agreed;
    });

    test('Confirm hire assigns the job and marks it direct', () async {
      final hired = await repo.confirmHire(
        agreed.id,
        idempotencyKey: newIdempotencyKey(),
      );
      expect(hired.status, JobStatus.assigned);
      expect(hired.directPayment, isTrue);
    });

    test('a country that pays in the app refuses the hire', () async {
      final country = db.users[customerId]!.countryCode;
      db.countryPacks[country] = db.countryPacks[country]!.copyWith(
        paymentMode: PaymentMode.inApp,
      );
      await expectLater(
        repo.confirmHire(agreed.id, idempotencyKey: newIdempotencyKey()),
        throwsA(expectCode('ERR_PAYMENT_REQUIRED')),
      );
    });

    test('goods are capped, need a receipt, and gate completion', () async {
      db.requests[agreed.id] = agreed.copyWith(
        status: JobStatus.inProgress,
        directPayment: true,
      );
      expect(db.requests[agreed.id]!.awaitsGoodsReceipt, isTrue);
      await expectLater(
        repo.requestStatusChange(
          agreed.id,
          JobStatus.completedByProvider,
          idempotencyKey: newIdempotencyKey(),
        ),
        throwsA(expectCode(ErrorCodes.proofRequired)),
      );
      await expectLater(
        repo.recordGoodsReceipt(
          jobId: agreed.id,
          spent: const Money(500001, 'NGN'),
          storagePath: '${agreed.id}/receipt.jpg',
          idempotencyKey: newIdempotencyKey(),
        ),
        throwsA(expectCode('ERR_GOODS_OVER_CAP')),
      );
      await expectLater(
        repo.recordGoodsReceipt(
          jobId: agreed.id,
          spent: const Money(325000, 'NGN'),
          idempotencyKey: newIdempotencyKey(),
        ),
        throwsA(expectCode(ErrorCodes.invalidArgument)),
      );
      final recorded = await repo.recordGoodsReceipt(
        jobId: agreed.id,
        spent: const Money(325000, 'NGN'),
        storagePath: '${agreed.id}/receipt.jpg',
        idempotencyKey: newIdempotencyKey(),
      );
      expect(recorded.directAmountDue, const Money(525000, 'NGN'));
      expect(recorded.awaitsGoodsReceipt, isFalse);
    });
  });
}
