import 'package:flutter_test/flutter_test.dart';
import 'package:suskii_domain/suskii_domain.dart';
import 'package:suskii_mobile/features/provider/provider_dashboard_header.dart';

void main() {
  group('maskAccount', () {
    test('two national digits, stars, the last digit', () {
      expect(maskAccount(phoneE164: '+2348012345675'), '80*******5');
      expect(maskAccount(phoneE164: '+254712345678'), '71******8');
      expect(maskAccount(phoneE164: '+27821234567'), '82******7');
    });

    test('an email account keeps its first letter and domain', () {
      expect(maskAccount(email: 'ada@example.com'), 'a***@example.com');
    });

    test('nothing to show: empty, and the name is used instead', () {
      expect(maskAccount(), '');
    });
  });

  group('goalPeriodEnd', () {
    test('a weekly goal starts again on the next Monday', () {
      // Saturday 24 October 2026.
      expect(
        goalPeriodEnd(GoalPeriod.weekly, DateTime(2026, 10, 24, 15)),
        DateTime(2026, 10, 26),
      );
      // A Monday counts towards this week, so it resets a week later.
      expect(
        goalPeriodEnd(GoalPeriod.weekly, DateTime(2026, 10, 26, 9)),
        DateTime(2026, 11, 2),
      );
    });

    test('a monthly goal starts again on the first, across the year', () {
      expect(
        goalPeriodEnd(GoalPeriod.monthly, DateTime(2026, 12, 31)),
        DateTime(2027),
      );
    });
  });
}
