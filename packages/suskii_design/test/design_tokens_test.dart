import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suskii_design/suskii_design.dart';

/// WCAG 2.x contrast ratio between two opaque colors.
double contrast(Color a, Color b) {
  double channel(double c) =>
      c <= 0.03928 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  double lum(Color c) =>
      0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
  final la = lum(a);
  final lb = lum(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

Color hex(String value) =>
    Color(int.parse('FF${value.replaceFirst('#', '')}', radix: 16));

void main() {
  for (final (String name, ThemeData theme) in <(String, ThemeData)>[
    ('dark', SAppTheme.dark()),
    ('light', SAppTheme.light()),
  ]) {
    group('$name theme contrast (WCAG AA)', () {
      final s = theme.colorScheme;
      final x = theme.extension<SuskiiColors>()!;
      final text = <String, (Color, Color)>{
        'onSurface/surface': (s.onSurface, s.surface),
        'onSurface/background': (s.onSurface, x.background),
        'onSurface/raised': (s.onSurface, x.surfaceRaised),
        'onSurface/high': (s.onSurface, s.surfaceContainerHighest),
        'secondary text/surface': (s.onSurfaceVariant, s.surface),
        'secondary text/raised': (s.onSurfaceVariant, x.surfaceRaised),
        'secondary text/high': (s.onSurfaceVariant, s.surfaceContainerHighest),
        'onPrimary/primary': (s.onPrimary, s.primary),
        'onSecondary/secondary': (s.onSecondary, s.secondary),
        'primary/surface': (s.primary, s.surface),
        'error/surface': (s.error, s.surface),
        'onError/error': (s.onError, s.error),
        'onPrimaryContainer': (s.onPrimaryContainer, s.primaryContainer),
        'onSecondaryContainer': (s.onSecondaryContainer, s.secondaryContainer),
        'onTertiaryContainer': (s.onTertiaryContainer, s.tertiaryContainer),
        'onErrorContainer': (s.onErrorContainer, s.errorContainer),
        'success/surface': (x.success, s.surface),
        'warning/surface': (x.warning, s.surface),
        'info/surface': (x.info, s.surface),
        'inverse': (s.onInverseSurface, s.inverseSurface),
      };
      for (final entry in text.entries) {
        test('${entry.key} >= 4.5', () {
          final (fg, bg) = entry.value;
          expect(contrast(fg, bg), greaterThanOrEqualTo(4.5));
        });
      }
      test('component boundary (outline) >= 3 on surfaces', () {
        expect(contrast(s.outline, s.surface), greaterThanOrEqualTo(3));
        expect(contrast(s.outline, x.surfaceRaised), greaterThanOrEqualTo(3));
      });
      test('text on the brand gradient >= 4.5 at every stop', () {
        for (final stop in x.gradient) {
          expect(contrast(x.onGradient, stop), greaterThanOrEqualTo(4.5));
        }
      });
    });
  }

  group('tokens.json mirrors the Dart tokens', () {
    final json = jsonDecode(
      File('../design-tokens/tokens.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final color = json['color'] as Map<String, dynamic>;
    final brand = color['brand'] as Map<String, dynamic>;
    final surface = color['surface'] as Map<String, dynamic>;
    final semantic = color['semantic'] as Map<String, dynamic>;

    void same(String path, String value, Color dart) =>
        expect(hex(value), dart, reason: path);

    test('brand', () {
      same('brand.primary', brand['primary'] as String, SColors.primaryLight);
      same(
        'brand.dark.primary',
        (brand['dark'] as Map<String, dynamic>)['primary'] as String,
        SColors.primaryDark,
      );
      same(
        'brand.secondary',
        brand['secondary'] as String,
        SColors.secondaryLight,
      );
      final gradient =
          (brand['gradient'] as Map<String, dynamic>)['dark'] as List<dynamic>;
      expect(
        gradient.map((dynamic v) => hex(v as String)).toList(),
        SuskiiColors.dark.gradient,
      );
    });

    test('surfaces and text', () {
      final dark = surface['dark'] as Map<String, dynamic>;
      final light = surface['light'] as Map<String, dynamic>;
      same(
        'surface.dark.background',
        dark['background'] as String,
        SColors.backgroundDark,
      );
      same(
        'surface.dark.surface',
        dark['surface'] as String,
        SColors.surfaceDark,
      );
      same(
        'surface.dark.textPrimary',
        dark['textPrimary'] as String,
        SColors.textPrimaryDark,
      );
      same(
        'surface.dark.outline',
        dark['outline'] as String,
        SColors.outlineDark,
      );
      same(
        'surface.light.surface',
        light['surface'] as String,
        SColors.surfaceLight,
      );
      same(
        'surface.light.textSecondary',
        light['textSecondary'] as String,
        SColors.textSecondaryLight,
      );
      same(
        'surface.light.outline',
        light['outline'] as String,
        SColors.outlineLight,
      );
    });

    test('semantic', () {
      final dark = semantic['dark'] as Map<String, dynamic>;
      final light = semantic['light'] as Map<String, dynamic>;
      same('semantic.dark.error', dark['error'] as String, SColors.errorDark);
      same(
        'semantic.light.success',
        light['success'] as String,
        SColors.successLight,
      );
    });

    test('spacing and radius', () {
      final spacing = json['spacing'] as Map<String, dynamic>;
      final radius = json['radius'] as Map<String, dynamic>;
      expect(spacing['gutter'], SSpacing.gutter);
      expect(spacing['minTouchTarget'], SSpacing.minTouchTarget);
      expect(radius['lg'], SRadius.lg);
      expect(radius['xl'], SRadius.xl);
    });
  });
}
