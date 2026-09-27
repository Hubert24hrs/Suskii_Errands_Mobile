import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suskii_domain/suskii_domain.dart';
import 'package:suskii_mobile/app/app.dart';
import 'package:suskii_mobile/app/providers.dart';
import 'package:suskii_mobile/app/router.dart';

import '../support/harness.dart';

/// Every route, rendered on the mock backend, in both themes and at 200%
/// text: a screen that throws, overflows or fails to lay out at the largest
/// text size the spec requires fails here (spec: text scaling to 200%).
///
/// Goldens for each route are recorded under `goldens/catalog/` with the
/// `golden` tag, so the default run stays fast and the recording is a
/// deliberate `flutter test --tags golden --update-goldens`.
const List<String> customerRoutes = <String>[
  AppRoutes.customerHome,
  AppRoutes.customerRequests,
  AppRoutes.customerMessages,
  AppRoutes.customerProfile,
  AppRoutes.customerRequestsNew,
  AppRoutes.customerConcierge,
  '/customer/requests/req-1',
  '/customer/requests/req-2',
  '/customer/requests/req-3/track',
  '/customer/requests/req-1/chat',
  '/customer/requests/req-6/pay',
  AppRoutes.customerWallet,
  AppRoutes.customerReferrals,
  AppRoutes.customerPromos,
  AppRoutes.customerDisputes,
  AppRoutes.customerSupport,
  '/customer/support/ticket-1',
  AppRoutes.customerSettings,
  AppRoutes.verifyCustomer,
  AppRoutes.providerOnboarding,
  AppRoutes.providerKyc,
];

const List<String> providerRoutes = <String>[
  AppRoutes.providerFeed,
  AppRoutes.providerJobs,
  AppRoutes.providerEarnings,
  AppRoutes.providerProfile,
  AppRoutes.providerOffers,
  AppRoutes.providerTools,
  AppRoutes.providerOrg,
];

String _slug(String route) =>
    route.replaceAll(RegExp('^/'), '').replaceAll(RegExp('[^a-z0-9]+'), '_');

Future<TestApp> _signedIn(
  WidgetTester tester, {
  ThemeMode mode = ThemeMode.dark,
  double textScale = 1,
  bool provider = false,
}) async {
  final app = await TestApp.pump(
    tester,
    themeMode: mode,
    textScale: textScale,
    prefs: const <String, Object>{'welcome_seen': true},
  );
  await signInThroughUi(tester);
  if (provider) {
    await app.run(
      tester,
      () => app.container
          .read(modeControllerProvider.notifier)
          .switchMode(UserMode.provider),
    );
    await settle(tester);
  }
  return app;
}

Future<void> _visit(WidgetTester tester, TestApp app, String route) async {
  app.container.read(routerProvider).go(route);
  await settle(tester);
  expect(tester.takeException(), isNull, reason: route);
  expect(
    app.container.read(routerProvider).state.matchedLocation,
    isNot(AppRoutes.startupError),
    reason: route,
  );
}

void main() {
  for (final double scale in <double>[1, 2]) {
    for (final ThemeMode mode in <ThemeMode>[ThemeMode.dark, ThemeMode.light]) {
      final label = '${mode.name} @${scale}x';
      testWidgets('customer screens render ($label)', (tester) async {
        final app = await _signedIn(tester, mode: mode, textScale: scale);
        for (final route in customerRoutes) {
          await _visit(tester, app, route);
        }
        await app.dispose(tester);
      });
      testWidgets('provider screens render ($label)', (tester) async {
        final app = await _signedIn(
          tester,
          mode: mode,
          textScale: scale,
          provider: true,
        );
        for (final route in providerRoutes) {
          await _visit(tester, app, route);
        }
        await app.dispose(tester);
      });
    }
  }

  for (final ThemeMode mode in <ThemeMode>[ThemeMode.dark, ThemeMode.light]) {
    testWidgets('catalog goldens: customer (${mode.name})', tags: 'golden', (
      tester,
    ) async {
      final app = await _signedIn(tester, mode: mode);
      for (final route in customerRoutes) {
        await _visit(tester, app, route);
        await expectLater(
          find.byType(SuskiiApp),
          matchesGoldenFile(
            '../goldens/catalog/${mode.name}/${_slug(route)}.png',
          ),
        );
      }
      await app.dispose(tester);
    });
    testWidgets('catalog goldens: provider (${mode.name})', tags: 'golden', (
      tester,
    ) async {
      final app = await _signedIn(tester, mode: mode, provider: true);
      for (final route in providerRoutes) {
        await _visit(tester, app, route);
        await expectLater(
          find.byType(SuskiiApp),
          matchesGoldenFile(
            '../goldens/catalog/${mode.name}/${_slug(route)}.png',
          ),
        );
      }
      await app.dispose(tester);
    });
  }
}
