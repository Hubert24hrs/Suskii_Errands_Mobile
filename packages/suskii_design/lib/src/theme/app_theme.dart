import 'package:flutter/material.dart';

import '../tokens/colors.dart';
import '../tokens/radius.dart';
import '../tokens/spacing.dart';
import '../tokens/typography.dart';

/// Builds the app ThemeData from tokens. Nothing here hardcodes a value that
/// a token owns.
abstract final class SAppTheme {
  static ThemeData light() => _base(_lightScheme());
  static ThemeData dark() => _base(_darkScheme());

  static ColorScheme _lightScheme() => const ColorScheme(
    brightness: Brightness.light,
    primary: SColors.brandPrimary,
    onPrimary: SColors.brandOnPrimary,
    primaryContainer: Color(0xFFBFE8DE),
    onPrimaryContainer: Color(0xFF06251F),
    secondary: SColors.brandSecondary,
    onSecondary: SColors.brandOnSecondary,
    secondaryContainer: Color(0xFFFBE3C8),
    onSecondaryContainer: Color(0xFF3A2200),
    tertiary: SColors.infoLight,
    onTertiary: Colors.white,
    error: SColors.errorLight,
    onError: Colors.white,
    errorContainer: Color(0xFFF9DEDC),
    onErrorContainer: Color(0xFF410E0B),
    surface: SColors.surfaceLight,
    onSurface: SColors.textPrimaryLight,
    surfaceContainerHighest: SColors.surfaceMutedLight,
    onSurfaceVariant: SColors.textSecondaryLight,
    outline: SColors.outlineLight,
    outlineVariant: Color(0xFFE1E7E4),
    shadow: Colors.black,
    inverseSurface: Color(0xFF242E2A),
    onInverseSurface: Color(0xFFEAF1EE),
    inversePrimary: Color(0xFF7FD6C3),
  );

  static ColorScheme _darkScheme() => const ColorScheme(
    brightness: Brightness.dark,
    primary: Color(0xFF7FD6C3),
    onPrimary: Color(0xFF06322A),
    primaryContainer: SColors.brandPrimaryStrong,
    onPrimaryContainer: Color(0xFFBFE8DE),
    secondary: Color(0xFFF7C08A),
    onSecondary: Color(0xFF4A3000),
    secondaryContainer: Color(0xFF6B4712),
    onSecondaryContainer: Color(0xFFFBE3C8),
    tertiary: SColors.infoDark,
    onTertiary: Color(0xFF0A2B4E),
    error: SColors.errorDark,
    onError: Color(0xFF601410),
    errorContainer: Color(0xFF8C1D18),
    onErrorContainer: Color(0xFFF9DEDC),
    surface: SColors.surfaceDark,
    onSurface: SColors.textPrimaryDark,
    surfaceContainerHighest: SColors.surfaceMutedDark,
    onSurfaceVariant: SColors.textSecondaryDark,
    outline: SColors.outlineDark,
    outlineVariant: Color(0xFF2A3530),
    shadow: Colors.black,
    inverseSurface: Color(0xFFEAF1EE),
    onInverseSurface: Color(0xFF242E2A),
    inversePrimary: SColors.brandPrimary,
  );

  static ThemeData _base(ColorScheme scheme) {
    final textTheme = STypography.textTheme(
      scheme.onSurface,
      scheme.onSurfaceVariant,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      textTheme: textTheme,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: textTheme.titleLarge,
      ),
      cardTheme: CardThemeData(
        color: scheme.brightness == Brightness.light
            ? SColors.surfaceRaisedLight
            : SColors.surfaceRaisedDark,
        elevation: 0,
        shape: const RoundedRectangleBorder(borderRadius: SRadius.borderMd),
        margin: EdgeInsets.zero,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest,
        border: const OutlineInputBorder(
          borderRadius: SRadius.borderMd,
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: SRadius.borderMd,
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: SRadius.borderMd,
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: SRadius.borderMd,
          borderSide: BorderSide(color: scheme.error),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: SSpacing.lg,
          vertical: SSpacing.md,
        ),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: scheme.surface,
        selectedItemColor: scheme.primary,
        unselectedItemColor: scheme.onSurfaceVariant,
        type: BottomNavigationBarType.fixed,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: const RoundedRectangleBorder(borderRadius: SRadius.borderMd),
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onInverseSurface,
        ),
      ),
      dialogTheme: const DialogThemeData(
        shape: RoundedRectangleBorder(borderRadius: SRadius.borderLg),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
      ),
    );
  }
}
