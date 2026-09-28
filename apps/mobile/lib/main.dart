import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_design/suskii_design.dart';

import 'app/app.dart';
import 'app/crash_reporting.dart';
import 'app/providers.dart';
import 'app/secure_session_storage.dart';

/// Single entrypoint; the flavor comes from --dart-define-from-file:
///   flutter run --flavor dev --dart-define-from-file=config/env/dev.json
///
/// Supabase is initialized only when the flavor carries a URL + anon key;
/// until a project is provisioned the app runs entirely on the mock layer.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final config = AppConfig.fromEnvironment();
  final info = await PackageInfo.fromPlatform();
  final prefs = await SharedPreferences.getInstance();
  registerDesignLicenses();

  await runWithCrashReporting(
    config,
    '${info.packageName}@${info.version}+${info.buildNumber}',
    () async {
      // Every layout is designed for portrait on phones (audit Y.24).
      await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
        DeviceOrientation.portraitUp,
      ]);
      if (!config.usesMockBackend) {
        await Supabase.initialize(
          url: config.supabaseUrl,
          publishableKey: config.supabaseAnonKey,
          authOptions: FlutterAuthClientOptions(
            localStorage: SecureSessionStorage(),
          ),
        );
      }
      runApp(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            appVersionProvider.overrideWithValue(
              '${info.version} (${info.buildNumber})',
            ),
          ],
          child: const SuskiiApp(),
        ),
      );
    },
  );
}
