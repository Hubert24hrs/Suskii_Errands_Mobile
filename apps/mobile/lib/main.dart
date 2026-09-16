import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';

/// Single entrypoint; the flavor comes from --dart-define-from-file:
///   flutter run --dart-define-from-file=config/env/dev.json
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: SuskiiApp()));
}
