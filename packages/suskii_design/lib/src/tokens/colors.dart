import 'package:flutter/material.dart';

/// Color tokens — PLACEHOLDER brand values ("Aurora"). Rebranding = edit this
/// file and `packages/design-tokens/tokens.json` together; nothing else
/// hard-codes a color.
///
/// Dark-first. Every text/surface pair clears WCAG AA (4.5:1) and every
/// component boundary 3:1; `design_tokens_test.dart` checks the pairs, so a
/// rebrand that breaks contrast fails CI rather than shipping.
abstract final class SColors {
  // Brand accents
  static const Color brandMint = Color(0xFF35E6B0);
  static const Color brandMintDeep = Color(0xFF087A5B);
  static const Color brandSky = Color(0xFF3FB8FF);
  static const Color brandViolet = Color(0xFF9A8CFF);
  static const Color brandVioletDeep = Color(0xFF5A44E0);

  /// Kept for the names the web tokens and older code use.
  static const Color brandPrimary = brandMintDeep;
  static const Color brandPrimaryStrong = Color(0xFF065E46);
  static const Color brandOnPrimary = Color(0xFFFFFFFF);
  static const Color brandSecondary = brandVioletDeep;
  static const Color brandOnSecondary = Color(0xFFFFFFFF);

  /// The signature gradient: buttons, the brand mark, hero surfaces.
  static const List<Color> auroraGradient = <Color>[
    brandMint,
    brandSky,
    brandViolet,
  ];

  // ---------------------------------------------------------------- dark ---
  static const Color backgroundDark = Color(0xFF070B14);
  static const Color surfaceDark = Color(0xFF0B1120);
  static const Color surfaceRaisedDark = Color(0xFF111A2C);
  static const Color surfaceMutedDark = Color(0xFF18223A);
  static const Color surfaceHighDark = Color(0xFF1F2B45);
  static const Color textPrimaryDark = Color(0xFFEEF2FB);
  static const Color textSecondaryDark = Color(0xFFA6B1C9);
  static const Color outlineDark = Color(0xFF63739A);
  static const Color outlineVariantDark = Color(0xFF2C3A57);

  static const Color primaryDark = brandMint;
  static const Color onPrimaryDark = Color(0xFF02170F);
  static const Color primaryContainerDark = Color(0xFF0C4636);
  static const Color onPrimaryContainerDark = Color(0xFFB8F6E2);
  static const Color secondaryDark = brandViolet;
  static const Color onSecondaryDark = Color(0xFF140B45);
  static const Color secondaryContainerDark = Color(0xFF2C2466);
  static const Color onSecondaryContainerDark = Color(0xFFDDD8FF);
  static const Color tertiaryContainerDark = Color(0xFF123B63);
  static const Color onTertiaryContainerDark = Color(0xFFCFE6FF);

  static const Color successDark = Color(0xFF4ADE9B);
  static const Color warningDark = Color(0xFFFFC14D);
  static const Color errorDark = Color(0xFFFF7C88);
  static const Color onErrorDark = Color(0xFF3D0710);
  static const Color errorContainerDark = Color(0xFF5C1620);
  static const Color onErrorContainerDark = Color(0xFFFFD9DD);
  static const Color infoDark = Color(0xFF6EBBFF);

  // --------------------------------------------------------------- light ---
  static const Color backgroundLight = Color(0xFFF4F6FB);
  static const Color surfaceLight = Color(0xFFF7F9FD);
  static const Color surfaceRaisedLight = Color(0xFFFFFFFF);
  static const Color surfaceMutedLight = Color(0xFFECF0F7);
  static const Color surfaceHighLight = Color(0xFFE3E9F3);
  static const Color textPrimaryLight = Color(0xFF0A1020);
  static const Color textSecondaryLight = Color(0xFF475470);
  static const Color outlineLight = Color(0xFF77849E);
  static const Color outlineVariantLight = Color(0xFFD7DEEA);

  static const Color primaryLight = brandMintDeep;
  static const Color onPrimaryLight = Color(0xFFFFFFFF);
  static const Color primaryContainerLight = Color(0xFFC8F4E6);
  static const Color onPrimaryContainerLight = Color(0xFF00382A);
  static const Color secondaryLight = brandVioletDeep;
  static const Color onSecondaryLight = Color(0xFFFFFFFF);
  static const Color secondaryContainerLight = Color(0xFFE3DEFF);
  static const Color onSecondaryContainerLight = Color(0xFF1D1060);
  static const Color tertiaryContainerLight = Color(0xFFDCEBFF);
  static const Color onTertiaryContainerLight = Color(0xFF0B2F60);

  static const Color successLight = Color(0xFF127A48);
  static const Color warningLight = Color(0xFF8A5800);
  static const Color errorLight = Color(0xFFC12D3B);
  static const Color onErrorLight = Color(0xFFFFFFFF);
  static const Color errorContainerLight = Color(0xFFFFE0E3);
  static const Color onErrorContainerLight = Color(0xFF5C0A14);
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
    glass: Color(0xB8111A2C),
    glassBorder: Color(0x33FFFFFF),
    gradient: SColors.auroraGradient,
    onGradient: SColors.onPrimaryDark,
    glow: Color(0x5535E6B0),
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
    glassBorder: Color(0x1A0A1020),
    gradient: <Color>[
      SColors.brandMintDeep,
      Color(0xFF1A6FC0),
      SColors.brandVioletDeep,
    ],
    onGradient: SColors.onPrimaryLight,
    glow: Color(0x33087A5B),
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
