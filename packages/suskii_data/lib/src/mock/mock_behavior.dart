import 'package:suskii_core/suskii_core.dart';

/// Tunables for the mock layer: simulated latency, offline mode, and failure
/// injection — so every screen's loading/empty/error/offline states are
/// demoable without a backend.
class MockBehavior {
  MockBehavior({
    this.latency = const Duration(milliseconds: 450),
    this.offline = false,
    this.failNextCalls = 0,
    this.currentUserId = 'user-ada',
    this.failLiveness = false,
    this.kycReviewDelay = const Duration(seconds: 4),
  });

  Duration latency;
  bool offline;
  int failNextCalls;
  String currentUserId;

  /// When true, liveness capture fails with a localizable reason key —
  /// demos the verification-failure path.
  bool failLiveness;

  /// Simulated review time before a submitted KYC step or verification
  /// session flips from in-review to its outcome.
  Duration kycReviewDelay;

  /// Skew of the simulated server clock vs the device clock (bootstrap
  /// `serverTime`). Non-zero by default to prove the ServerClock mechanism.
  Duration serverClockSkew = const Duration(seconds: 7);

  /// Overrides per-category offer TTL (tests use a short value so expiry is
  /// observable fast). Null → use the category's `offerTtlSeconds`.
  Duration? offerTtlOverride;

  /// Simulated gateway delay before an initialized payment confirms via the
  /// (mocked) webhook + server-side verify.
  Duration paymentConfirmDelay = const Duration(seconds: 3);

  /// When true, the next initialized payment confirms as FAILED (gateway
  /// decline) instead of HELD — demos the payment-failure path.
  bool failNextPayment = false;

  /// Simulated ops-review delay before an open/in-review dispute resolves
  /// with a partial refund (M5 dispute-center demo).
  Duration disputeResolveDelay = const Duration(seconds: 5);

  /// Simulated delay before the AI first-line triage replies to a new
  /// support-ticket message.
  Duration supportTriageDelay = const Duration(seconds: 2);

  Future<void> gate() async {
    await Future<void>.delayed(latency);
    if (offline) {
      throw const AppError(ErrorCodes.network);
    }
    if (failNextCalls > 0) {
      failNextCalls--;
      throw const AppError(ErrorCodes.unknown);
    }
  }
}
