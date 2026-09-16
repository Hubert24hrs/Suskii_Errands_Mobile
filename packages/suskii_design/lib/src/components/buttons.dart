import 'package:flutter/material.dart';

import '../tokens/radius.dart';
import '../tokens/spacing.dart';

enum SButtonVariant { primary, secondary, ghost, danger }

/// The one button. Min 48dp touch target, built-in loading state.
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
    final scheme = Theme.of(context).colorScheme;
    final disabled = onPressed == null || loading;

    final (bg, fg, border) = switch (variant) {
      SButtonVariant.primary => (
        scheme.primary,
        scheme.onPrimary,
        Colors.transparent,
      ),
      SButtonVariant.secondary => (
        scheme.secondaryContainer,
        scheme.onSecondaryContainer,
        Colors.transparent,
      ),
      SButtonVariant.ghost => (
        Colors.transparent,
        scheme.primary,
        scheme.outline,
      ),
      SButtonVariant.danger => (
        scheme.error,
        scheme.onError,
        Colors.transparent,
      ),
    };

    final child = loading
        ? SizedBox(
            height: 22,
            width: 22,
            child: CircularProgressIndicator(strokeWidth: 2.5, color: fg),
          )
        : Row(
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
          );

    return Semantics(
      button: true,
      enabled: !disabled,
      label: label,
      child: SizedBox(
        width: expand ? double.infinity : null,
        height: SSpacing.minTouchTarget,
        child: Material(
          color: disabled ? scheme.surfaceContainerHighest : bg,
          borderRadius: SRadius.borderMd,
          child: InkWell(
            onTap: disabled ? null : onPressed,
            borderRadius: SRadius.borderMd,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: SRadius.borderMd,
                border: Border.all(
                  color: disabled ? scheme.surfaceContainerHighest : border,
                ),
              ),
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: SSpacing.lg),
              child: DefaultTextStyle.merge(
                style: Theme.of(context).textTheme.labelLarge
                    ?.copyWith(color: disabled ? scheme.onSurfaceVariant : fg),
                child: IconTheme.merge(
                  data: IconThemeData(
                    color: disabled ? scheme.onSurfaceVariant : fg,
                  ),
                  child: child,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
