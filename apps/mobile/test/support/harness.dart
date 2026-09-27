import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:suskii_data/suskii_data.dart';
import 'package:suskii_mobile/app/app.dart';
import 'package:suskii_mobile/app/providers.dart';

/// Phone-sized viewport used by every screen and flow test (iPhone 13 at
/// 3x): the layouts are designed for it, and goldens need one size.
const Size kPhoneSize = Size(390, 844);

bool _fontsLoaded = false;

/// Loads the bundled Sora and Manrope fonts and the Material icon font, so
/// screenshots show real type instead of the test font's boxes.
Future<void> loadAppFonts() async {
  if (_fontsLoaded) return;
  Future<void> load(String family, List<String> assets) async {
    final loader = FontLoader(family);
    for (final asset in assets) {
      loader.addFont(rootBundle.load(asset));
    }
    await loader.load();
  }

  await load('packages/suskii_design/Sora', <String>[
    'packages/suskii_design/assets/fonts/Sora-Variable.ttf',
  ]);
  await load('packages/suskii_design/Manrope', <String>[
    'packages/suskii_design/assets/fonts/Manrope-Variable.ttf',
  ]);
  await load('MaterialIcons', <String>['fonts/MaterialIcons-Regular.otf']);
  _fontsLoaded = true;
}

/// A running app on the mock backend, and the handles a test needs.
class TestApp {
  TestApp._(this.container, this.behavior, this.database);

  final ProviderContainer container;
  final MockBehavior behavior;
  final MockDatabase database;
  bool _disposed = false;

  /// Unmounts the app, disposes every provider (their mock streams poll on
  /// timers) and lets the remaining fake timers run out, so the test ends
  /// with nothing pending. Call at the end of every test.
  Future<void> dispose(WidgetTester tester) async {
    if (_disposed) return;
    _disposed = true;
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(seconds: 10));
    }
  }

  /// Runs [action] (a repository or controller call that awaits mock
  /// latency) while pumping frames, so its timers fire under fake async.
  Future<T> run<T>(WidgetTester tester, Future<T> Function() action) async {
    final future = action();
    await settle(tester);
    return future;
  }

  /// Builds [SuskiiApp] with zero mock latency and the given stored
  /// preferences (for example `{'welcome_seen': true}` to skip first run).
  static Future<TestApp> pump(
    WidgetTester tester, {
    Map<String, Object> prefs = const <String, Object>{},
    ThemeMode themeMode = ThemeMode.dark,
    Locale? locale,
    double textScale = 1,
    Size size = kPhoneSize,
    // 1x keeps the recorded goldens small; layout is identical at any ratio.
    double pixelRatio = 1,
    List<Override> overrides = const <Override>[],
  }) async {
    await loadAppFonts();
    tester.view
      ..physicalSize = size * pixelRatio
      ..devicePixelRatio = pixelRatio;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    SharedPreferences.setMockInitialValues(<String, Object>{
      'theme_mode': themeMode.name,
      'locale': ?locale?.languageCode,
      ...prefs,
    });
    final sharedPreferences = await SharedPreferences.getInstance();
    final behavior =
        MockBehavior(
            latency: Duration.zero,
            kycReviewDelay: const Duration(milliseconds: 200),
          )
          ..paymentConfirmDelay = const Duration(milliseconds: 200)
          ..disputeResolveDelay = const Duration(milliseconds: 200)
          ..supportTriageDelay = const Duration(milliseconds: 200);
    final database = MockDatabase();
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(sharedPreferences),
        mockBehaviorProvider.overrideWithValue(behavior),
        mockDatabaseProvider.overrideWithValue(database),
        appVersionProvider.overrideWithValue('1.0.0 (1)'),
        ...overrides,
      ],
    );
    final app = TestApp._(container, behavior, database);
    addTearDown(() {
      if (!app._disposed) container.dispose();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const SuskiiApp()),
    );
    await settle(tester);
    return app;
  }
}

/// Pumps frames until nothing is scheduled or [timeout] of fake time has
/// passed. Unlike `pumpAndSettle` it tolerates the endless animations a
/// real app has (progress indicators, shimmer) instead of throwing.
Future<void> settle(
  WidgetTester tester, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  var elapsed = Duration.zero;
  const step = Duration(milliseconds: 50);
  await tester.pump();
  while (elapsed < timeout) {
    await tester.pump(step);
    elapsed += step;
    if (!tester.binding.hasScheduledFrame) break;
  }
}

/// Signs in through the real auth screen, as a person would.
Future<void> signInThroughUi(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const ValueKey<String>('auth.identity')),
    '08031234567',
  );
  await tester.tap(find.byKey(const ValueKey<String>('auth.send')));
  await settle(tester);
  await tester.enterText(
    find.byKey(const ValueKey<String>('auth.code')),
    '123456',
  );
  await settle(tester);
}

/// Waits for a pending microtask-driven future inside fake async.
Future<void> flush(WidgetTester tester) =>
    tester.runAsync(() => Future<void>.delayed(Duration.zero));
