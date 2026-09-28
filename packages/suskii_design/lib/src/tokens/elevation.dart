import 'package:flutter/widgets.dart';

/// Elevation tokens. Surfaces separate by tone and hairline borders rather
/// than drop shadows; the only shadow is the soft glow under brand elements.
abstract final class SElevation {
  static const double none = 0;
  static const double raised = 1;
  static const double overlay = 3;
  static const double modal = 6;

  /// The glow under gradient buttons and the brand mark.
  ///
  /// Inset by its own offset, so where blur is not rendered (low-end GPUs,
  /// tests) the shadow hides behind the element instead of showing a slab.
  static List<BoxShadow> glow(Color color) => <BoxShadow>[
    BoxShadow(
      color: color,
      blurRadius: 22,
      spreadRadius: -6,
      offset: const Offset(0, 6),
    ),
  ];
}

/// Backdrop blur strengths for glass surfaces.
abstract final class SBlur {
  static const double glass = 24;
  static const double heavy = 40;
}
