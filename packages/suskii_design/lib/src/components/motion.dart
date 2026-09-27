import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../tokens/motion.dart';

/// Haptic vocabulary. One place, so the app's touch language is consistent:
/// selection for toggles and pickers, light for taps that do something,
/// success for an action the server confirmed, warning for a refusal.
abstract final class SHaptics {
  static void selection() => unawaited(HapticFeedback.selectionClick());
  static void light() => unawaited(HapticFeedback.lightImpact());
  static void success() => unawaited(HapticFeedback.mediumImpact());
  static void warning() => unawaited(HapticFeedback.heavyImpact());
}

/// Scales its child down slightly while pressed — the tactile micro-
/// interaction under buttons, cards and tiles. Purely visual: the tap is
/// handled by the child (InkWell, button); this only listens.
class SPressable extends StatefulWidget {
  const SPressable({required this.child, super.key, this.enabled = true});

  final Widget child;
  final bool enabled;

  @override
  State<SPressable> createState() => _SPressableState();
}

class _SPressableState extends State<SPressable> {
  bool _pressed = false;

  void _set(bool value) {
    if (!widget.enabled || _pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => _set(true),
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1,
        duration: SMotion.of(context, SMotion.instant),
        curve: SMotion.standard,
        child: widget.child,
      ),
    );
  }
}

/// Fades and slides its child in once, [index] steps after its siblings —
/// the staggered entrance for lists and grids. Skipped entirely under
/// reduced motion.
class SFadeSlideIn extends StatelessWidget {
  const SFadeSlideIn({
    required this.child,
    super.key,
    this.index = 0,
    this.offset = 16,
  });

  final Widget child;
  final int index;
  final double offset;

  @override
  Widget build(BuildContext context) {
    final duration = SMotion.of(context, SMotion.normal);
    if (duration == Duration.zero) return child;
    // Cap the delay so a long list does not keep the user waiting.
    final delay = SMotion.stagger * index.clamp(0, 8);
    final total = duration + delay;
    final start = delay.inMilliseconds / total.inMilliseconds;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: total,
      curve: Interval(start, 1, curve: SMotion.decelerate),
      builder: (BuildContext context, double t, Widget? child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, offset * (1 - t)),
          child: child,
        ),
      ),
      child: child,
    );
  }
}

/// Section title with an optional trailing action ("View all").
class SSectionHeader extends StatelessWidget {
  const SSectionHeader({
    required this.title,
    super.key,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: <Widget>[
        Expanded(
          child: Semantics(
            header: true,
            child: Text(title, style: theme.textTheme.titleLarge),
          ),
        ),
        if (actionLabel != null && onAction != null)
          TextButton(onPressed: onAction, child: Text(actionLabel!)),
      ],
    );
  }
}
