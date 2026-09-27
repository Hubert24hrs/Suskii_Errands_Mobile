@Tags(<String>['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suskii_mobile/app/app.dart';

import '../support/harness.dart';

/// The first-run journey, screen by screen, in both themes: welcome →
/// onboarding → sign-in → home. These are the goldens the redesign is
/// reviewed against; `flutter test --update-goldens` re-records them.
void main() {
  for (final ThemeMode mode in <ThemeMode>[ThemeMode.dark, ThemeMode.light]) {
    final theme = mode.name;
    testWidgets('first run ($theme)', (tester) async {
      final app = await TestApp.pump(tester, themeMode: mode);
      await expectLater(
        find.byType(SuskiiApp),
        matchesGoldenFile('../goldens/welcome_$theme.png'),
      );

      await tester.tap(find.byKey(const ValueKey<String>('welcome.continue')));
      await settle(tester);
      await expectLater(
        find.byType(SuskiiApp),
        matchesGoldenFile('../goldens/onboarding_$theme.png'),
      );

      for (var i = 0; i < 3; i++) {
        await tester.tap(find.byKey(const ValueKey<String>('onboarding.next')));
        await settle(tester);
      }
      await expectLater(
        find.byType(SuskiiApp),
        matchesGoldenFile('../goldens/auth_$theme.png'),
      );

      await signInThroughUi(tester);
      await expectLater(
        find.byType(SuskiiApp),
        matchesGoldenFile('../goldens/home_$theme.png'),
      );
      await app.dispose(tester);
    });
  }
}
