/// Server-clock offset captured at bootstrap (`AppBootstrap.serverTime`).
/// Every countdown in the UI — offer TTL, payment TTL, auto-confirm — renders
/// against server time with this measured offset, so a device with a wrong
/// clock still shows the correct deadline.
///
/// Lives in core (not domain): it is cross-cutting app infrastructure like
/// logging and connectivity, keeping the domain package pure business types.
class ServerClock {
  DateTime? _serverAtSync;
  DateTime? _deviceAtSync;
  final Stopwatch _sinceSync = Stopwatch();

  bool get isSynced => _serverAtSync != null;

  /// Measured offset (server − device) at the last [sync].
  Duration? get offset =>
      isSynced ? _serverAtSync!.difference(_deviceAtSync!) : null;

  /// Capture the offset from a bootstrap `serverTime` (UTC).
  void sync(DateTime serverTime) {
    _serverAtSync = serverTime;
    _deviceAtSync = DateTime.now();
    _sinceSync
      ..stop()
      ..reset()
      ..start();
  }

  /// Server time now, extrapolated from the captured offset via a monotonic
  /// [Stopwatch] — immune to device-clock jumps after [sync]. Falls back to
  /// the device clock when [sync] was never called.
  DateTime now() {
    if (!isSynced) return DateTime.now();
    return _serverAtSync!.add(_sinceSync.elapsed);
  }

  /// Time remaining until a server-supplied deadline (e.g. `Offer.expiresAt`).
  Duration remaining(DateTime serverDeadline) =>
      serverDeadline.difference(now());
}
