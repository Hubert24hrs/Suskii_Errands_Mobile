import 'package:flutter/material.dart';

import '../tokens/colors.dart';
import '../tokens/elevation.dart';
import '../tokens/motion.dart';
import '../tokens/radius.dart';
import '../tokens/spacing.dart';
import 'motion.dart';

enum SButtonVariant { primary, secondary, ghost, danger }

/// The one button. Primary is the brand gradient with a soft glow; the rest
/// are tonal. Min 48dp touch target, built-in loading state, a press scale
/// and a light haptic on tap.
class SButton extends StatelessWidget {
  const SButton({
    required this.label,
    super.key,
    this.onPressed,
    this.variant = SButtonVariant.primary,
    this.loading = false,
    this.icon,
    this.expand = true,
  });

  final String label;
  final VoidCallback? onPressed;
  final SButtonVariant variant;
  final bool loading;
  final IconData? icon;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final palette = context.sColors;
    final disabled = onPressed == null || loading;

    final (
      Color fg,
      Color? bg,
      Gradient? gradient,
      BorderSide border,
    ) = switch (variant) {
      SButtonVariant.primary => (
        palette.onGradient,
        null,
        LinearGradient(colors: palette.gradient),
        BorderSide.none,
      ),
      SButtonVariant.secondary => (
        scheme.onSurface,
        scheme.surfaceContainerHighest,
        null,
        BorderSide(color: scheme.outlineVariant),
      ),
      SButtonVariant.ghost => (
        scheme.primary,
        Colors.transparent,
        null,
        BorderSide(color: scheme.outline),
      ),
      SButtonVariant.danger => (
        scheme.onError,
        scheme.error,
        null,
        BorderSide.none,
      ),
    };

    final foreground = disabled ? scheme.onSurfaceVariant : fg;
    final decoration = BoxDecoration(
      color: disabled ? scheme.surfaceContainerHigh : bg,
      gradient: disabled ? null : gradient,
      borderRadius: SRadius.borderMd,
      border: border == BorderSide.none
          ? null
          : Border.fromBorderSide(
              disabled ? BorderSide(color: scheme.outlineVariant) : border,
            ),
      boxShadow: !disabled && gradient != null
          ? SElevation.glow(palette.glow)
          : null,
    );

    final content = AnimatedSwitcher(
      duration: SMotion.of(context, SMotion.fast),
      child: loading
          ? SizedBox(
              key: const ValueKey<String>('loading'),
              height: 22,
              width: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: foreground,
              ),
            )
          : Row(
              key: const ValueKey<String>('label'),
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                if (icon != null) ...<Widget>[
                  Icon(icon, size: 20),
                  const SizedBox(width: SSpacing.sm),
                ],
                Flexible(
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
              ],
            ),
    );

    return Semantics(
      button: true,
      enabled: !disabled,
      label: label,
      excludeSemantics: true,
      child: SPressable(
        enabled: !disabled,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: SSpacing.minTouchTarget + 4,
            minWidth: expand ? double.infinity : SSpacing.minTouchTarget,
          ),
          child: AnimatedContainer(
            duration: SMotion.of(context, SMotion.fast),
            decoration: decoration,
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                onTap: disabled
                    ? null
                    : () {
                        SHaptics.light();
                        onPressed!();
                      },
                borderRadius: SRadius.borderMd,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: SSpacing.xl,
                    vertical: SSpacing.md,
                  ),
                  child: Center(
                    widthFactor: expand ? null : 1,
                    child: DefaultTextStyle.merge(
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: foreground,
                      ),
                      child: IconTheme.merge(
                        data: IconThemeData(color: foreground),
                        child: content,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
