import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:suskii_core/suskii_core.dart';

import 'app/app.dart';

/// Single entrypoint; the flavor comes from --dart-define-from-file:
///   flutter run --dart-define-from-file=config/env/dev.json
///
/// Supabase is initialized only when the flavor carries a URL + anon key;
/// until a project is provisioned the app runs entirely on the mock layer.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final config = AppConfig.fromEnvironment();
  if (config.supabaseUrl.isNotEmpty && config.supabaseAnonKey.isNotEmpty) {
    await Supabase.initialize(
      url: config.supabaseUrl,
      publishableKey: config.supabaseAnonKey,
    );
  }
  runApp(const ProviderScope(child: SuskiiApp()));
}
