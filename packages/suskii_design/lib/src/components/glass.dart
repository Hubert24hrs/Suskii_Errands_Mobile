import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../tokens/colors.dart';
import '../tokens/elevation.dart';
import '../tokens/radius.dart';
import '../tokens/spacing.dart';

/// A frosted-glass surface: blurred backdrop, translucent fill, hairline
/// border. The signature container of the design system.
class SGlass extends StatelessWidget {
  const SGlass({
    required this.child,
    super.key,
    this.padding = const EdgeInsets.all(SSpacing.lg),
    this.borderRadius = SRadius.borderLg,
    this.blur = SBlur.glass,
    this.color,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final BorderRadius borderRadius;
  final double blur;

  /// Overrides the theme's glass fill.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final palette = context.sColors;
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: color ?? palette.glass,
            borderRadius: borderRadius,
            border: Border.all(color: palette.glassBorder),
          ),
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// A decorative backdrop of soft aurora light behind hero screens (splash,
/// welcome, sign-in, home header). Static — it draws once and never
/// animates, so it costs nothing on a low-end device.
class SAuroraBackground extends StatelessWidget {
  const SAuroraBackground({required this.child, super.key, this.intensity = 1});

  final Widget child;

  /// 0–1; lower on content-heavy screens so text stays calm.
  final double intensity;

  @override
  Widget build(BuildContext context) {
    final palette = context.sColors;
    return DecoratedBox(
      decoration: BoxDecoration(color: palette.background),
      child: CustomPaint(
        painter: _AuroraPainter(
          colors: palette.gradient,
          dark: Theme.of(context).brightness == Brightness.dark,
          intensity: intensity.clamp(0, 1).toDouble(),
        ),
        child: child,
      ),
    );
  }
}

class _AuroraPainter extends CustomPainter {
  _AuroraPainter({
    required this.colors,
    required this.dark,
    required this.intensity,
  });

  final List<Color> colors;
  final bool dark;
  final double intensity;

  @override
  void paint(Canvas canvas, Size size) {
    final alpha = (dark ? 0.34 : 0.22) * intensity;
    void orb(Offset center, double radius, Color color) {
      final paint = Paint()
        ..shader = RadialGradient(
          colors: <Color>[
            color.withValues(alpha: alpha),
            color.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromCircle(center: center, radius: radius));
      canvas.drawCircle(center, radius, paint);
    }

    final w = size.width;
    final h = size.height;
    orb(Offset(w * 0.05, h * 0.02), w * 0.9, colors.first);
    orb(Offset(w * 1.0, h * 0.18), w * 0.75, colors[colors.length ~/ 2]);
    orb(Offset(w * 0.55, h * 0.95), w * 0.8, colors.last);
  }

  @override
  bool shouldRepaint(_AuroraPainter old) =>
      old.dark != dark || old.intensity != intensity || old.colors != colors;
}

/// The placeholder brand mark: a rounded tile filled with the brand
/// gradient. Wrapped in a [Hero] so it travels from splash to welcome to
/// sign-in. Swap the glyph for the real logo when brand assets exist.
class SBrandMark extends StatelessWidget {
  const SBrandMark({super.key, this.size = 72, this.heroTag = 'brand-mark'});

  final double size;
  final Object? heroTag;

  @override
  Widget build(BuildContext context) {
    final palette = context.sColors;
    final mark = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: palette.gradient,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(size * 0.3),
        boxShadow: SElevation.glow(palette.glow),
      ),
      alignment: Alignment.center,
      child: Icon(
        Icons.bolt_rounded,
        size: size * 0.56,
        color: palette.onGradient,
      ),
    );
    return Semantics(
      excludeSemantics: true,
      child: heroTag == null ? mark : Hero(tag: heroTag!, child: mark),
    );
  }
}

/// Paints [child] (usually text or an icon) with the brand gradient.
class SGradientMask extends StatelessWidget {
  const SGradientMask({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.sColors.gradient;
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (Rect bounds) =>
          LinearGradient(colors: colors).createShader(bounds),
      child: child,
    );
  }
}

/// An icon in a soft gradient disc — for empty states, onboarding and
/// category tiles.
class SIconOrb extends StatelessWidget {
  const SIconOrb({required this.icon, super.key, this.size = 56});

  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    final palette = context.sColors;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: <Color>[
            for (final c in palette.gradient) c.withValues(alpha: 0.2),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: palette.glassBorder),
      ),
      alignment: Alignment.center,
      child: SGradientMask(child: Icon(icon, size: size * 0.48)),
    );
  }
}
