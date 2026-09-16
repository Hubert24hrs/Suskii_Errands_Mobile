import 'dart:developer' as developer;

enum LogLevel { debug, info, warning, error }

/// App-wide logging contract. Implementations MUST NOT log sensitive data:
/// no tokens, phone numbers, OTP codes, ID numbers, payout details, or
/// precise home coordinates.
abstract interface class AppLogger {
  void log(LogLevel level, String message, {Object? error, StackTrace? stack});
}

/// Development logger backed by dart:developer. Release builds will wire a
/// Sentry-backed logger (crash reporting without PII).
final class ConsoleAppLogger implements AppLogger {
  const ConsoleAppLogger();

  @override
  void log(LogLevel level, String message, {Object? error, StackTrace? stack}) {
    developer.log(
      message,
      level: switch (level) {
        LogLevel.debug => 500,
        LogLevel.info => 800,
        LogLevel.warning => 900,
        LogLevel.error => 1000,
      },
      error: error,
      stackTrace: stack,
      name: 'suskii',
    );
  }
}
