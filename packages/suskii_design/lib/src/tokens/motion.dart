import 'package:flutter/animation.dart';

/// Motion tokens — durations and curves.
abstract final class SMotion {
  static const Duration fast = Duration(milliseconds: 150);
  static const Duration normal = Duration(milliseconds: 250);
  static const Duration slow = Duration(milliseconds: 400);

  /// Mode-switch shell transition.
  static const Duration shellSwitch = Duration(milliseconds: 300);

  static const Curve emphasized = Curves.easeInOutCubicEmphasized;
  static const Curve standard = Curves.easeOutCubic;
}
