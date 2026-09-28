import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:suskii_domain/suskii_domain.dart';
import 'package:suskii_mobile/app/providers.dart';
import 'package:suskii_mobile/app/router.dart';

import '../test/support/harness.dart';

/// Store screenshots, on a real device or simulator so the platform's own
/// fonts render every glyph (the test font has no ₦). The plan, sizes and
/// the commands are in fastlane/screenshots/README.md:
///
///   flutter drive --driver=test_driver/screenshot_driver.dart \
///     --target=integration_test/store_screenshots_test.dart -d <device>
///
/// The mock backend supplies the data, so every run shows the same people,
/// prices and jobs.
const List<(String, String)> customerShots = <(String, String)>[
  ('01_home', AppRoutes.customerHome),
  ('02_offers', '/customer/requests/req-1'),
  ('03_tracking', '/customer/requests/req-3/track'),
  ('04_payment', '/customer/requests/req-6/pay'),
  ('05_chat', '/customer/requests/req-2/chat'),
  ('06_wallet', AppRoutes.customerWallet),
];

const List<(String, String)> providerShots = <(String, String)>[
  ('07_provider_feed', AppRoutes.providerFeed),
  ('08_provider_jobs', AppRoutes.providerJobs),
];

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  for (final mode in <ThemeMode>[ThemeMode.dark, ThemeMode.light]) {
    testWidgets('store screenshots (${mode.name})', (tester) async {
      final app = await TestApp.pump(
        tester,
        themeMode: mode,
        size: tester.view.physicalSize / tester.view.devicePixelRatio,
        pixelRatio: tester.view.devicePixelRatio,
        prefs: const <String, Object>{'welcome_seen': true},
      );
      await binding.convertFlutterSurfaceToImage();
      await signInThroughUi(tester);

      Future<void> shoot(String name, String route) async {
        app.container.read(routerProvider).go(route);
        await settle(tester);
        await binding.takeScreenshot('${mode.name}_$name');
      }

      for (final (name, route) in customerShots) {
        await shoot(name, route);
      }
      await app.run(
        tester,
        () => app.container
            .read(modeControllerProvider.notifier)
            .switchMode(UserMode.provider),
      );
      for (final (name, route) in providerShots) {
        await shoot(name, route);
      }
      await app.dispose(tester);
    });
  }
}
