import 'package:flutter/material.dart';

/// Typography. Sora (display, headlines, titles) for a bold, geometric voice;
/// Manrope (body, labels) for legibility at small sizes. Both SIL OFL,
/// bundled in `assets/fonts`, so the app never downloads a font and works
/// offline. Sizes are logical and scale with the system text size.
abstract final class STypography {
  static const String displayFamily = 'Sora';
  static const String bodyFamily = 'Manrope';
  static const String package = 'suskii_design';

  static TextStyle _display(
    double size,
    FontWeight weight,
    double height,
    double tracking,
    Color color,
  ) => TextStyle(
    fontFamily: displayFamily,
    package: package,
    fontSize: size,
    fontWeight: weight,
    fontVariations: <FontVariation>[
      FontVariation.weight(weight.value.toDouble()),
    ],
    height: height,
    letterSpacing: tracking,
    color: color,
  );

  static TextStyle _body(
    double size,
    FontWeight weight,
    double height,
    Color color, {
    double tracking = 0,
  }) => TextStyle(
    fontFamily: bodyFamily,
    package: package,
    fontSize: size,
    fontWeight: weight,
    fontVariations: <FontVariation>[
      FontVariation.weight(weight.value.toDouble()),
    ],
    height: height,
    letterSpacing: tracking,
    color: color,
  );

  static TextTheme textTheme(Color primary, Color secondary) => TextTheme(
    displayLarge: _display(48, FontWeight.w700, 1.08, -1.2, primary),
    displayMedium: _display(40, FontWeight.w700, 1.1, -1, primary),
    displaySmall: _display(34, FontWeight.w700, 1.12, -0.8, primary),
    headlineLarge: _display(30, FontWeight.w700, 1.18, -0.6, primary),
    headlineMedium: _display(26, FontWeight.w700, 1.2, -0.5, primary),
    headlineSmall: _display(22, FontWeight.w600, 1.25, -0.3, primary),
    titleLarge: _display(19, FontWeight.w600, 1.3, -0.2, primary),
    titleMedium: _body(16, FontWeight.w700, 1.35, primary),
    titleSmall: _body(14, FontWeight.w700, 1.35, primary),
    bodyLarge: _body(16, FontWeight.w500, 1.5, primary),
    bodyMedium: _body(14, FontWeight.w500, 1.45, primary),
    bodySmall: _body(12.5, FontWeight.w500, 1.4, secondary),
    labelLarge: _body(15, FontWeight.w700, 1.25, primary, tracking: 0.1),
    labelMedium: _body(13, FontWeight.w700, 1.25, primary, tracking: 0.2),
    labelSmall: _body(11.5, FontWeight.w700, 1.3, secondary, tracking: 0.4),
  );
}
