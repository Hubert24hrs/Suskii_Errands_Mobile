import 'package:flutter/widgets.dart';

/// Motion tokens — durations and curves. Fluid, never slow: most transitions
/// land under 300ms, and every animation collapses to nothing when the
/// platform asks for reduced motion ([SMotion.of]).
abstract final class SMotion {
  static const Duration instant = Duration(milliseconds: 90);
  static const Duration fast = Duration(milliseconds: 160);
  static const Duration normal = Duration(milliseconds: 260);
  static const Duration slow = Duration(milliseconds: 420);

  /// Page and shared-axis transitions.
  static const Duration page = Duration(milliseconds: 380);

  /// Mode-switch shell transition.
  static const Duration shellSwitch = Duration(milliseconds: 320);

  /// Delay between items of a staggered list entrance.
  static const Duration stagger = Duration(milliseconds: 45);

  static const Curve emphasized = Curves.easeInOutCubicEmphasized;
  static const Curve standard = Curves.easeOutCubic;
  static const Curve decelerate = Curves.easeOutQuart;
  static const Curve spring = Curves.easeOutBack;

  /// [duration], or zero when the user asked the platform to reduce motion.
  static Duration of(BuildContext context, Duration duration) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false
      ? Duration.zero
      : duration;
}
