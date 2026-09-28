import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../tokens/colors.dart';
import '../tokens/radius.dart';
import '../tokens/spacing.dart';
import '../tokens/typography.dart';

/// Builds the app ThemeData from tokens. Nothing here hardcodes a value that
/// a token owns; screens style themselves through this theme and the
/// [SuskiiColors] extension, never with literal colors.
abstract final class SAppTheme {
  static ThemeData light() => _base(_lightScheme(), SuskiiColors.light);
  static ThemeData dark() => _base(_darkScheme(), SuskiiColors.dark);

  static ColorScheme _lightScheme() => const ColorScheme(
    brightness: Brightness.light,
    primary: SColors.primaryLight,
    onPrimary: SColors.onPrimaryLight,
    primaryContainer: SColors.primaryContainerLight,
    onPrimaryContainer: SColors.onPrimaryContainerLight,
    secondary: SColors.secondaryLight,
    onSecondary: SColors.onSecondaryLight,
    secondaryContainer: SColors.secondaryContainerLight,
    onSecondaryContainer: SColors.onSecondaryContainerLight,
    tertiary: SColors.infoLight,
    onTertiary: SColors.onPrimaryLight,
    tertiaryContainer: SColors.tertiaryContainerLight,
    onTertiaryContainer: SColors.onTertiaryContainerLight,
    error: SColors.errorLight,
    onError: SColors.onErrorLight,
    errorContainer: SColors.errorContainerLight,
    onErrorContainer: SColors.onErrorContainerLight,
    surface: SColors.surfaceLight,
    onSurface: SColors.textPrimaryLight,
    surfaceContainerLowest: SColors.surfaceRaisedLight,
    surfaceContainerLow: SColors.surfaceRaisedLight,
    surfaceContainer: SColors.surfaceMutedLight,
    surfaceContainerHigh: SColors.surfaceMutedLight,
    surfaceContainerHighest: SColors.surfaceHighLight,
    onSurfaceVariant: SColors.textSecondaryLight,
    outline: SColors.outlineLight,
    outlineVariant: SColors.outlineVariantLight,
    shadow: SColors.textPrimaryLight,
    scrim: SColors.textPrimaryLight,
    inverseSurface: SColors.surfaceDark,
    onInverseSurface: SColors.textPrimaryDark,
    inversePrimary: SColors.primaryDark,
    surfaceTint: Colors.transparent,
  );

  static ColorScheme _darkScheme() => const ColorScheme(
    brightness: Brightness.dark,
    primary: SColors.primaryDark,
    onPrimary: SColors.onPrimaryDark,
    primaryContainer: SColors.primaryContainerDark,
    onPrimaryContainer: SColors.onPrimaryContainerDark,
    secondary: SColors.secondaryDark,
    onSecondary: SColors.onSecondaryDark,
    secondaryContainer: SColors.secondaryContainerDark,
    onSecondaryContainer: SColors.onSecondaryContainerDark,
    tertiary: SColors.infoDark,
    onTertiary: SColors.onPrimaryDark,
    tertiaryContainer: SColors.tertiaryContainerDark,
    onTertiaryContainer: SColors.onTertiaryContainerDark,
    error: SColors.errorDark,
    onError: SColors.onErrorDark,
    errorContainer: SColors.errorContainerDark,
    onErrorContainer: SColors.onErrorContainerDark,
    surface: SColors.surfaceDark,
    onSurface: SColors.textPrimaryDark,
    surfaceContainerLowest: SColors.backgroundDark,
    surfaceContainerLow: SColors.surfaceRaisedDark,
    surfaceContainer: SColors.surfaceRaisedDark,
    surfaceContainerHigh: SColors.surfaceMutedDark,
    surfaceContainerHighest: SColors.surfaceHighDark,
    onSurfaceVariant: SColors.textSecondaryDark,
    outline: SColors.outlineDark,
    outlineVariant: SColors.outlineVariantDark,
    shadow: Colors.black,
    scrim: Colors.black,
    inverseSurface: SColors.surfaceLight,
    onInverseSurface: SColors.textPrimaryLight,
    inversePrimary: SColors.primaryLight,
    surfaceTint: Colors.transparent,
  );

  static ThemeData _base(ColorScheme scheme, SuskiiColors extra) {
    final textTheme = STypography.textTheme(
      scheme.onSurface,
      scheme.onSurfaceVariant,
    );
    const controlShape = RoundedRectangleBorder(borderRadius: SRadius.borderMd);
    const minSize = Size(SSpacing.minTouchTarget, SSpacing.minTouchTarget);
    OutlineInputBorder border(Color color, [double width = 1]) =>
        OutlineInputBorder(
          borderRadius: SRadius.borderMd,
          borderSide: BorderSide(color: color, width: width),
        );

    return ThemeData(
      useMaterial3: true,
      brightness: scheme.brightness,
      colorScheme: scheme,
      textTheme: textTheme,
      fontFamily: STypography.bodyFamily,
      package: STypography.package,
      scaffoldBackgroundColor: extra.background,
      canvasColor: extra.background,
      extensions: <ThemeExtension<dynamic>>[extra],
      splashFactory: InkSparkle.splashFactory,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      visualDensity: VisualDensity.standard,
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.fuchsia: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
          // Keep the native swipe-back on Apple platforms.
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
        },
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: extra.background,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleSpacing: SSpacing.gutter,
        titleTextStyle: textTheme.titleLarge,
      ),
      cardTheme: CardThemeData(
        color: extra.surfaceRaised,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: SRadius.borderLg,
          side: BorderSide(color: scheme.outlineVariant),
        ),
        margin: const EdgeInsets.symmetric(vertical: SSpacing.xs),
        clipBehavior: Clip.antiAlias,
      ),
      listTileTheme: ListTileThemeData(
        iconColor: scheme.onSurfaceVariant,
        textColor: scheme.onSurface,
        titleTextStyle: textTheme.titleSmall,
        subtitleTextStyle: textTheme.bodySmall,
        minVerticalPadding: SSpacing.md,
        contentPadding: const EdgeInsets.symmetric(horizontal: SSpacing.lg),
        shape: const RoundedRectangleBorder(borderRadius: SRadius.borderMd),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHigh,
        border: border(scheme.outline),
        enabledBorder: border(scheme.outline),
        focusedBorder: border(scheme.primary, 2),
        errorBorder: border(scheme.error),
        focusedErrorBorder: border(scheme.error, 2),
        disabledBorder: border(scheme.outlineVariant),
        labelStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
        floatingLabelStyle: textTheme.labelMedium?.copyWith(
          color: scheme.primary,
        ),
        hintStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
        helperStyle: textTheme.bodySmall,
        errorStyle: textTheme.bodySmall?.copyWith(color: scheme.error),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: SSpacing.lg,
          vertical: SSpacing.lg,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: minSize,
          shape: controlShape,
          textStyle: textTheme.labelLarge,
          padding: const EdgeInsets.symmetric(horizontal: SSpacing.xl),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          minimumSize: minSize,
          shape: controlShape,
          elevation: 0,
          backgroundColor: scheme.surfaceContainerHigh,
          foregroundColor: scheme.onSurface,
          textStyle: textTheme.labelLarge,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: minSize,
          shape: controlShape,
          side: BorderSide(color: scheme.outline),
          foregroundColor: scheme.onSurface,
          textStyle: textTheme.labelLarge,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: minSize,
          shape: controlShape,
          foregroundColor: scheme.primary,
          textStyle: textTheme.labelLarge,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(minimumSize: minSize),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          minimumSize: minSize,
          backgroundColor: scheme.surfaceContainerHigh,
          foregroundColor: scheme.onSurfaceVariant,
          selectedBackgroundColor: scheme.primaryContainer,
          selectedForegroundColor: scheme.onPrimaryContainer,
          side: BorderSide(color: scheme.outlineVariant),
          textStyle: textTheme.labelMedium,
          shape: const RoundedRectangleBorder(borderRadius: SRadius.borderPill),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        elevation: 0,
        focusElevation: 0,
        hoverElevation: 0,
        highlightElevation: 0,
        shape: const RoundedRectangleBorder(borderRadius: SRadius.borderLg),
        extendedTextStyle: textTheme.labelLarge,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: extra.glass,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        height: 72,
        indicatorColor: scheme.primary.withValues(alpha: 0.16),
        indicatorShape: const StadiumBorder(),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            size: 24,
            color: states.contains(WidgetState.selected)
                ? scheme.primary
                : scheme.onSurfaceVariant,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => textTheme.labelSmall?.copyWith(
            color: states.contains(WidgetState.selected)
                ? scheme.onSurface
                : scheme.onSurfaceVariant,
          ),
        ),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: extra.glass,
        selectedItemColor: scheme.primary,
        unselectedItemColor: scheme.onSurfaceVariant,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: extra.surfaceRaised,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: extra.surfaceRaised,
        showDragHandle: true,
        dragHandleColor: scheme.outline,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(SRadius.xl)),
        ),
        clipBehavior: Clip.antiAlias,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: extra.surfaceRaised,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(borderRadius: SRadius.borderXl),
        titleTextStyle: textTheme.headlineSmall,
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        elevation: 0,
        shape: const RoundedRectangleBorder(borderRadius: SRadius.borderMd),
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onInverseSurface,
        ),
        actionTextColor: scheme.inversePrimary,
        insetPadding: const EdgeInsets.all(SSpacing.lg),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        selectedColor: scheme.primaryContainer,
        side: BorderSide(color: scheme.outlineVariant),
        labelStyle: textTheme.labelMedium,
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(
          horizontal: SSpacing.sm,
          vertical: SSpacing.xs,
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.onPrimary
              : scheme.outline,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.primary
              : scheme.surfaceContainerHighest,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? Colors.transparent
              : scheme.outline,
        ),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.primary
              : scheme.outline,
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.primary
              : Colors.transparent,
        ),
        checkColor: WidgetStatePropertyAll<Color>(scheme.onPrimary),
        side: BorderSide(color: scheme.outline, width: 1.5),
        shape: const RoundedRectangleBorder(borderRadius: SRadius.borderXs),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: scheme.surfaceContainerHighest,
        circularTrackColor: Colors.transparent,
        linearMinHeight: 6,
        borderRadius: SRadius.borderPill,
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: scheme.primary,
        inactiveTrackColor: scheme.surfaceContainerHighest,
        thumbColor: scheme.primary,
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
        space: 1,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: scheme.inverseSurface,
          borderRadius: SRadius.borderSm,
        ),
        textStyle: textTheme.bodySmall?.copyWith(
          color: scheme.onInverseSurface,
        ),
      ),
      badgeTheme: BadgeThemeData(
        backgroundColor: scheme.error,
        textColor: scheme.onError,
      ),
    );
  }
}
