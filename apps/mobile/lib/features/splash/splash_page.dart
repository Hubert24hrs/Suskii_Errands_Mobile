import 'package:flutter/material.dart';
import 'package:suskii_design/suskii_design.dart';
import 'package:suskii_l10n/suskii_l10n.dart';

/// Branded cold-start screen. The router's redirect moves on as soon as
/// bootstrap/auth resolve — this page never navigates itself. The brand mark
/// is a Hero, so it glides into the welcome and sign-in screens.
class SplashPage extends StatelessWidget {
  const SplashPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      body: SAuroraBackground(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(SSpacing.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const SBrandMark(size: 96),
                const SizedBox(height: SSpacing.xl),
                Text(
                  l10n.appName,
                  style: theme.textTheme.displaySmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: SSpacing.sm),
                Text(
                  l10n.appTagline,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: SSpacing.xxl),
                const SizedBox(width: 120, child: LinearProgressIndicator()),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
