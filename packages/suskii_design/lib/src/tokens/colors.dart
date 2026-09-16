import 'package:flutter/material.dart';

/// Color tokens — PLACEHOLDER brand values. Rebranding = edit this file only.
///
/// Contrast targets WCAG AA: text colors on their paired surfaces exceed 4.5:1.
abstract final class SColors {
  // Brand
  static const Color brandPrimary = Color(0xFF0E7C66); // deep teal
  static const Color brandPrimaryStrong = Color(0xFF0A5A4B);
  static const Color brandOnPrimary = Color(0xFFFFFFFF);
  static const Color brandSecondary = Color(0xFFF4A259); // warm amber
  static const Color brandOnSecondary = Color(0xFF3A2200);

  // Semantic — light
  static const Color successLight = Color(0xFF1B7F3B);
  static const Color warningLight = Color(0xFF9A6700);
  static const Color errorLight = Color(0xFFB3261E);
  static const Color infoLight = Color(0xFF0B5CAD);

  // Semantic — dark (brightened for contrast on dark surfaces)
  static const Color successDark = Color(0xFF6FD38A);
  static const Color warningDark = Color(0xFFF2C14E);
  static const Color errorDark = Color(0xFFF2B8B5);
  static const Color infoDark = Color(0xFF9CC3F2);

  // Surfaces & text — light
  static const Color surfaceLight = Color(0xFFFDFDFC);
  static const Color surfaceRaisedLight = Color(0xFFFFFFFF);
  static const Color surfaceMutedLight = Color(0xFFF1F3F2);
  static const Color textPrimaryLight = Color(0xFF15211D);
  static const Color textSecondaryLight = Color(0xFF4A5A54);
  static const Color outlineLight = Color(0xFFC7D0CC);

  // Surfaces & text — dark
  static const Color surfaceDark = Color(0xFF101614);
  static const Color surfaceRaisedDark = Color(0xFF18201D);
  static const Color surfaceMutedDark = Color(0xFF212B27);
  static const Color textPrimaryDark = Color(0xFFEAF1EE);
  static const Color textSecondaryDark = Color(0xFFAAB8B2);
  static const Color outlineDark = Color(0xFF3A4742);
}
