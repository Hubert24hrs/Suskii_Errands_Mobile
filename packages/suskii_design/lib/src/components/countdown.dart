import 'dart:async';

import 'package:flutter/material.dart';

/// Countdown to a deadline (offer TTL, payment TTL). Renders `mm:ss`;
/// turns to the theme error color under [urgentThreshold].
///
/// Deadlines are server timestamps, so pass the measured server-clock offset
/// (`ServerClock.offset`, server − device) via [clockOffset]; without it the
/// countdown trusts the device clock.
class SCountdownTimer extends StatefulWidget {
  const SCountdownTimer({
    required this.deadline,
    super.key,
    this.clockOffset,
    this.onExpired,
    this.urgentThreshold = const Duration(minutes: 2),
    this.textStyle,
  });

  final DateTime deadline;

  /// Measured server − device clock offset; added to the device clock so a
  /// device with a wrong clock still counts down to the server deadline.
  final Duration? clockOffset;

  final VoidCallback? onExpired;
  final Duration urgentThreshold;
  final TextStyle? textStyle;

  @override
  State<SCountdownTimer> createState() => _SCountdownTimerState();
}

class _SCountdownTimerState extends State<SCountdownTimer> {
  Timer? _timer;
  Duration _remaining = Duration.zero;

  @override
  void initState() {
    super.initState();
    _tick();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _tick() {
    final now = DateTime.now().add(widget.clockOffset ?? Duration.zero);
    final remaining = widget.deadline.difference(now);
    if (!mounted) return;
    setState(
      () => _remaining = remaining.isNegative ? Duration.zero : remaining,
    );
    if (remaining.isNegative) {
      _timer?.cancel();
      widget.onExpired?.call();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final minutes = _remaining.inMinutes
        .remainder(60)
        .toString()
        .padLeft(2, '0');
    final hours = _remaining.inHours;
    final seconds = _remaining.inSeconds
        .remainder(60)
        .toString()
        .padLeft(2, '0');
    final text = hours > 0
        ? '$hours:${_remaining.inMinutes.remainder(60).toString().padLeft(2, '0')}:$seconds'
        : '$minutes:$seconds';
    final urgent = _remaining <= widget.urgentThreshold;
    final base = widget.textStyle ?? Theme.of(context).textTheme.labelLarge;
    return Text(
      text,
      semanticsLabel: text,
      style: base?.copyWith(
        color: urgent ? Theme.of(context).colorScheme.error : null,
        fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
      ),
    );
  }
}
