import 'package:flutter/material.dart';

/// Color tokens — the Suskii Errands brand, taken from the logo: signal red,
/// orange and amber on a deep navy, with the wordmark's royal blue as the
/// secondary. Rebranding = edit this file and
/// `packages/design-tokens/tokens.json` together; nothing else hard-codes a
/// color.
///
/// Dark-first. Every text/surface pair clears WCAG AA (4.5:1) and every
/// component boundary 3:1; `design_tokens_test.dart` checks the pairs, so a
/// rebrand that breaks contrast fails CI rather than shipping. The logo's
/// pure #EF1E00 and #FE8802 are too light to carry white text, so the light
/// theme uses deeper shades of the same hues.
abstract final class SColors {
  // Brand accents, as the logo draws them.
  static const Color brandRed = Color(0xFFEF1E00);
  static const Color brandRedDeep = Color(0xFFC41A0A);
  static const Color brandOrange = Color(0xFFFE8802);
  static const Color brandAmber = Color(0xFFF7AF0B);
  static const Color brandBlue = Color(0xFF093095);
  static const Color brandBlueLight = Color(0xFF8FA8FF);
  static const Color brandNavy = Color(0xFF050B18);

  static const Color brandPrimary = brandRedDeep;
  static const Color brandPrimaryStrong = Color(0xFF9E1408);
  static const Color brandOnPrimary = Color(0xFFFFFFFF);
  static const Color brandSecondary = brandBlue;
  static const Color brandOnSecondary = Color(0xFFFFFFFF);

  /// The signature gradient on dark: buttons, hero surfaces.
  static const List<Color> brandGradient = <Color>[
    Color(0xFFFF4D2E),
    Color(0xFFFF7F1F),
    Color(0xFFFFB524),
  ];

  // ---------------------------------------------------------------- dark ---
  static const Color backgroundDark = brandNavy;
  static const Color surfaceDark = Color(0xFF0A1222);
  static const Color surfaceRaisedDark = Color(0xFF101A2E);
  static const Color surfaceMutedDark = Color(0xFF172238);
  static const Color surfaceHighDark = Color(0xFF1E2B45);
  static const Color textPrimaryDark = Color(0xFFF2F3F8);
  static const Color textSecondaryDark = Color(0xFFA9B2C8);
  static const Color outlineDark = Color(0xFF66749A);
  static const Color outlineVariantDark = Color(0xFF2C3A57);

  static const Color primaryDark = Color(0xFFFF7A45);
  static const Color onPrimaryDark = Color(0xFF1F0500);
  static const Color primaryContainerDark = Color(0xFF5A1A08);
  static const Color onPrimaryContainerDark = Color(0xFFFFDCCF);
  static const Color secondaryDark = brandBlueLight;
  static const Color onSecondaryDark = Color(0xFF061A55);
  static const Color secondaryContainerDark = Color(0xFF1D2E70);
  static const Color onSecondaryContainerDark = Color(0xFFDCE3FF);
  static const Color tertiaryContainerDark = Color(0xFF4A3300);
  static const Color onTertiaryContainerDark = Color(0xFFFFE7B0);

  static const Color successDark = Color(0xFF4ADE9B);
  static const Color warningDark = Color(0xFFFFC14D);
  static const Color errorDark = Color(0xFFFF7C96);
  static const Color onErrorDark = Color(0xFF3D0712);
  static const Color errorContainerDark = Color(0xFF5C1626);
  static const Color onErrorContainerDark = Color(0xFFFFD9E0);
  static const Color infoDark = Color(0xFF6EBBFF);

  // --------------------------------------------------------------- light ---
  static const Color backgroundLight = Color(0xFFFBF7F5);
  static const Color surfaceLight = Color(0xFFFDFAF8);
  static const Color surfaceRaisedLight = Color(0xFFFFFFFF);
  static const Color surfaceMutedLight = Color(0xFFF6EEEA);
  static const Color surfaceHighLight = Color(0xFFEFE4DF);
  static const Color textPrimaryLight = Color(0xFF0B1636);
  static const Color textSecondaryLight = Color(0xFF4A5270);
  static const Color outlineLight = Color(0xFF7E8096);
  static const Color outlineVariantLight = Color(0xFFE8DCD6);

  static const Color primaryLight = brandRedDeep;
  static const Color onPrimaryLight = Color(0xFFFFFFFF);
  static const Color primaryContainerLight = Color(0xFFFFE1D9);
  static const Color onPrimaryContainerLight = Color(0xFF5A0A02);
  static const Color secondaryLight = brandBlue;
  static const Color onSecondaryLight = Color(0xFFFFFFFF);
  static const Color secondaryContainerLight = Color(0xFFDDE5FF);
  static const Color onSecondaryContainerLight = Color(0xFF0A1E5C);
  static const Color tertiaryContainerLight = Color(0xFFFFEBC2);
  static const Color onTertiaryContainerLight = Color(0xFF4A3000);

  static const Color successLight = Color(0xFF127A48);
  static const Color warningLight = Color(0xFF8A5800);
  static const Color errorLight = Color(0xFFB0123E);
  static const Color onErrorLight = Color(0xFFFFFFFF);
  static const Color errorContainerLight = Color(0xFFFFDDE4);
  static const Color onErrorContainerLight = Color(0xFF5C0A1E);
  static const Color infoLight = Color(0xFF1760C4);
}

/// Colors the Material [ColorScheme] has no slot for — semantic status,
/// glass surfaces, the brand gradient. Read with `context.sColors`.
@immutable
class SuskiiColors extends ThemeExtension<SuskiiColors> {
  const SuskiiColors({
    required this.background,
    required this.surfaceRaised,
    required this.success,
    required this.warning,
    required this.info,
    required this.glass,
    required this.glassBorder,
    required this.gradient,
    required this.onGradient,
    required this.glow,
    required this.shimmerBase,
    required this.shimmerHighlight,
  });

  final Color background;
  final Color surfaceRaised;
  final Color success;
  final Color warning;
  final Color info;

  /// Translucent fill for blurred surfaces (nav bar, sheets, hero cards).
  final Color glass;

  /// Hairline border that catches the light on a glass edge.
  final Color glassBorder;
  final List<Color> gradient;

  /// Text and icons on the gradient (AA against every stop).
  final Color onGradient;

  /// Soft shadow color under gradient elements.
  final Color glow;
  final Color shimmerBase;
  final Color shimmerHighlight;

  static const SuskiiColors dark = SuskiiColors(
    background: SColors.backgroundDark,
    surfaceRaised: SColors.surfaceRaisedDark,
    success: SColors.successDark,
    warning: SColors.warningDark,
    info: SColors.infoDark,
    glass: Color(0xB8101A2E),
    glassBorder: Color(0x33FFFFFF),
    gradient: SColors.brandGradient,
    onGradient: SColors.onPrimaryDark,
    glow: Color(0x55FF6A2E),
    shimmerBase: SColors.surfaceMutedDark,
    shimmerHighlight: SColors.surfaceHighDark,
  );

  static const SuskiiColors light = SuskiiColors(
    background: SColors.backgroundLight,
    surfaceRaised: SColors.surfaceRaisedLight,
    success: SColors.successLight,
    warning: SColors.warningLight,
    info: SColors.infoLight,
    glass: Color(0xCCFFFFFF),
    glassBorder: Color(0x1A0B1636),
    gradient: <Color>[Color(0xFFB81506), Color(0xFFD02A06), Color(0xFFC24400)],
    onGradient: SColors.onPrimaryLight,
    glow: Color(0x33C41A0A),
    shimmerBase: SColors.surfaceMutedLight,
    shimmerHighlight: SColors.surfaceRaisedLight,
  );

  @override
  SuskiiColors copyWith({
    Color? background,
    Color? surfaceRaised,
    Color? success,
    Color? warning,
    Color? info,
    Color? glass,
    Color? glassBorder,
    List<Color>? gradient,
    Color? onGradient,
    Color? glow,
    Color? shimmerBase,
    Color? shimmerHighlight,
  }) => SuskiiColors(
    background: background ?? this.background,
    surfaceRaised: surfaceRaised ?? this.surfaceRaised,
    success: success ?? this.success,
    warning: warning ?? this.warning,
    info: info ?? this.info,
    glass: glass ?? this.glass,
    glassBorder: glassBorder ?? this.glassBorder,
    gradient: gradient ?? this.gradient,
    onGradient: onGradient ?? this.onGradient,
    glow: glow ?? this.glow,
    shimmerBase: shimmerBase ?? this.shimmerBase,
    shimmerHighlight: shimmerHighlight ?? this.shimmerHighlight,
  );

  @override
  SuskiiColors lerp(covariant SuskiiColors? other, double t) {
    if (other == null) return this;
    return SuskiiColors(
      background: Color.lerp(background, other.background, t)!,
      surfaceRaised: Color.lerp(surfaceRaised, other.surfaceRaised, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      info: Color.lerp(info, other.info, t)!,
      glass: Color.lerp(glass, other.glass, t)!,
      glassBorder: Color.lerp(glassBorder, other.glassBorder, t)!,
      gradient: <Color>[
        for (var i = 0; i < gradient.length; i++)
          Color.lerp(
            gradient[i],
            other.gradient[i % other.gradient.length],
            t,
          )!,
      ],
      onGradient: Color.lerp(onGradient, other.onGradient, t)!,
      glow: Color.lerp(glow, other.glow, t)!,
      shimmerBase: Color.lerp(shimmerBase, other.shimmerBase, t)!,
      shimmerHighlight: Color.lerp(
        shimmerHighlight,
        other.shimmerHighlight,
        t,
      )!,
    );
  }
}

extension SuskiiColorsContext on BuildContext {
  /// The design system's extra colors for the current theme.
  SuskiiColors get sColors =>
      Theme.of(this).extension<SuskiiColors>() ??
      (Theme.of(this).brightness == Brightness.dark
          ? SuskiiColors.dark
          : SuskiiColors.light);
}
