import 'package:flutter/material.dart';

import '../tokens/colors.dart';
import '../tokens/spacing.dart';
import 'buttons.dart';
import 'glass.dart';
import 'motion.dart';

/// Empty list / no-content placeholder.
class SEmptyState extends StatelessWidget {
  const SEmptyState({
    required this.icon,
    required this.title,
    super.key,
    this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SFadeSlideIn(
        child: Padding(
          padding: const EdgeInsets.all(SSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SIconOrb(icon: icon, size: 72),
              const SizedBox(height: SSpacing.lg),
              Text(
                title,
                style: theme.textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              if (message != null) ...<Widget>[
                const SizedBox(height: SSpacing.sm),
                Text(
                  message!,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
              if (actionLabel != null && onAction != null) ...<Widget>[
                const SizedBox(height: SSpacing.xl),
                SButton(
                  label: actionLabel!,
                  variant: SButtonVariant.secondary,
                  expand: false,
                  onPressed: onAction,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Recoverable error with retry.
class SErrorState extends StatelessWidget {
  const SErrorState({
    required this.title,
    required this.retryLabel,
    super.key,
    this.message,
    this.onRetry,
  });

  final String title;
  final String retryLabel;
  final String? message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(SSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: scheme.errorContainer,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.wifi_tethering_error_rounded,
                size: 32,
                color: scheme.onErrorContainer,
              ),
            ),
            const SizedBox(height: SSpacing.lg),
            Semantics(
              liveRegion: true,
              child: Text(
                title,
                style: theme.textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
            ),
            if (message != null) ...<Widget>[
              const SizedBox(height: SSpacing.sm),
              Text(
                message!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: SSpacing.xl),
            SButton(
              label: retryLabel,
              variant: SButtonVariant.secondary,
              icon: Icons.refresh_rounded,
              expand: false,
              onPressed: onRetry,
            ),
          ],
        ),
      ),
    );
  }
}

/// Slim banner shown when connectivity is lost; content stays visible.
class SOfflineBanner extends StatelessWidget {
  const SOfflineBanner({required this.label, super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final palette = context.sColors;
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: ColoredBox(
        color: scheme.surfaceContainerHigh,
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: SSpacing.lg,
              vertical: SSpacing.sm,
            ),
            child: Row(
              children: <Widget>[
                Icon(Icons.cloud_off_rounded, size: 18, color: palette.warning),
                const SizedBox(width: SSpacing.sm),
                Expanded(
                  child: Text(
                    label,
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurface),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
