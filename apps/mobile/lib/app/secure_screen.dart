import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Blocks screenshots and screen recording while mounted, on Android via
/// FLAG_SECURE (`MainActivity`). iOS cannot block a screenshot; it covers
/// the app-switcher snapshot instead (`AppDelegate`), for every screen.
/// Wrap KYC, wallet, PIN and payout screens (audit 2026-09-27 Y.16; spec
/// security.mobile).
class SecureScreen extends StatefulWidget {
  const SecureScreen({required this.child, super.key});

  final Widget child;

  static const MethodChannel _channel = MethodChannel('suskii/secure_screen');

  static Future<void> _set(bool secure) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod<void>('setSecure', secure);
    } on MissingPluginException {
      // Tests and platforms without the channel: nothing to protect.
    } on PlatformException {
      // Never fail a screen because the flag could not be set.
    }
  }

  @override
  State<SecureScreen> createState() => _SecureScreenState();
}

class _SecureScreenState extends State<SecureScreen> {
  // Nested secure screens (a sheet over a KYC page) must not clear the flag
  // when the inner one closes.
  static int _depth = 0;

  @override
  void initState() {
    super.initState();
    if (_depth++ == 0) unawaited(SecureScreen._set(true));
  }

  @override
  void dispose() {
    if (--_depth == 0) unawaited(SecureScreen._set(false));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
