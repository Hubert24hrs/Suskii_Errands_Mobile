import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

/// Writes each screenshot the test takes to fastlane/screenshots/<platform>/,
/// where fastlane's metadata lanes (or a person) pick them up.
Future<void> main() => integrationDriver(
  onScreenshot: (name, bytes, [args]) async {
    final platform = Platform.environment['SCREENSHOT_PLATFORM'] ?? 'device';
    final file = File('fastlane/screenshots/$platform/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
    return true;
  },
);
