import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:suskii_core/suskii_core.dart';

/// Crash and error reporting (audit 2026-09-27 Y.15). Off unless the flavor
/// carries a DSN. Nothing personal leaves the device: no user, no request
/// bodies, no breadcrumbs from HTTP, no screenshots (spec security.mobile:
/// "No sensitive data in logs, analytics events, or crash reports").
Future<void> runWithCrashReporting(
  AppConfig config,
  String release,
  Future<void> Function() appRunner,
) async {
  if (config.sentryDsn.isEmpty) {
    await appRunner();
    return;
  }
  await SentryFlutter.init((options) {
    options
      ..dsn = config.sentryDsn
      ..environment = config.flavor.name
      ..release = release
      ..sendDefaultPii = false
      ..attachScreenshot = false
      ..enableAutoPerformanceTracing = false
      ..beforeSend = scrubEvent
      ..beforeBreadcrumb = scrubBreadcrumb;
  }, appRunner: appRunner);
}

/// Strips identity and request payloads from an event before it is sent.
SentryEvent? scrubEvent(SentryEvent event, Hint hint) {
  event
    ..user = null
    ..request = null
    ..serverName = null;
  return event;
}

/// HTTP breadcrumbs carry URLs with ids and query strings; drop them.
Breadcrumb? scrubBreadcrumb(Breadcrumb? breadcrumb, Hint hint) {
  if (breadcrumb == null) return null;
  if (breadcrumb.type == 'http' || breadcrumb.category == 'http') return null;
  return breadcrumb;
}
