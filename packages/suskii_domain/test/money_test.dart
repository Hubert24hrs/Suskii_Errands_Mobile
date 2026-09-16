import 'package:suskii_domain/suskii_domain.dart';
import 'package:test/test.dart';

void main() {
  group('Money', () {
    test('exponents follow ISO 4217 (default 2, explicit 0/3 overrides)', () {
      expect(Money.exponentOf('NGN'), 2);
      expect(Money.exponentOf('USD'), 2);
      expect(Money.exponentOf('XOF'), 0);
      expect(Money.exponentOf('RWF'), 0);
      expect(Money.exponentOf('KWD'), 3);
    });

    test('fromMajorUnits respects exponent', () {
      expect(Money.fromMajorUnits(100, 'USD').minorUnits, 10000);
      expect(Money.fromMajorUnits(4500, 'XOF').minorUnits, 4500);
    });

    test('arithmetic guards currency mismatch', () {
      const a = Money(1000, 'NGN');
      const b = Money(500, 'NGN');
      expect((a + b).minorUnits, 1500);
      expect((a - b).minorUnits, 500);
      expect(() => a + const Money(1, 'KES'), throwsArgumentError);
      expect(() => a.compareTo(const Money(1, 'USD')), throwsArgumentError);
    });

    test('comparison operators', () {
      const a = Money(1000, 'NGN');
      const b = Money(500, 'NGN');
      expect(a > b, isTrue);
      expect(a <= b, isFalse);
      expect(a >= const Money(1000, 'NGN'), isTrue);
    });

    test('formats with symbol, grouping and exponent-aware decimals', () {
      expect(const Money(1250000, 'NGN').format(), '₦12,500.00');
      expect(const Money(4500, 'XOF').format(), 'CFA 4,500');
      expect(const Money(-525, 'USD').format(), r'-$5.25');
      expect(const Money(870500, 'KES').format(), 'KSh 8,705.00');
      expect(const Money(1234567, 'KWD').format(), 'KWD 1,234.567');
    });

    test('equality is currency-insensitive to case only', () {
      expect(const Money(1, 'ngn'), const Money(1, 'NGN'));
      expect(const Money(1, 'NGN') == const Money(2, 'NGN'), isFalse);
    });

    test('json round-trip', () {
      const m = Money(8750, 'USD');
      expect(Money.fromJson(m.toJson()), m);
    });
  });

  group('JobStatus', () {
    test('terminal states', () {
      expect(JobStatus.closed.isTerminal, isTrue);
      expect(JobStatus.cancelled.isTerminal, isTrue);
      expect(JobStatus.inProgress.isTerminal, isFalse);
    });

    test('needsAttention covers active-job banner states', () {
      expect(JobStatus.enRoute.needsAttention, isTrue);
      expect(JobStatus.disputed.needsAttention, isTrue);
      expect(JobStatus.settled.needsAttention, isFalse);
    });
  });
}
