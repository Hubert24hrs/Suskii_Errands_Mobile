import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:suskii_design/suskii_design.dart';
import 'package:suskii_domain/suskii_domain.dart';
import 'package:suskii_l10n/suskii_l10n.dart';

import '../../app/providers.dart';
import '../../app/router.dart';

/// M2 placeholder shown once after sign-in: previews multi-factor
/// authentication. Acknowledging (or skipping) lands on the mode's home —
/// the router redirect enforces the rest.
class MfaPromptPage extends ConsumerWidget {
  const MfaPromptPage({super.key});

  void _dismiss(BuildContext context, WidgetRef ref) {
    ref.read(mfaAcknowledgedProvider.notifier).set(true);
    context.go(
      ref.read(modeControllerProvider) == UserMode.provider
          ? AppRoutes.providerFeed
          : AppRoutes.customerHome,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(SSpacing.xl),
          child: Column(
            children: <Widget>[
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => _dismiss(context, ref),
                  child: Text(l10n.onboardingSkip),
                ),
              ),
              const Spacer(),
              Icon(
                Icons.shield_outlined,
                size: 96,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: SSpacing.xl),
              Text(
                l10n.mfaTitle,
                style: theme.textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: SSpacing.md),
              Text(
                l10n.mfaBody,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const Spacer(),
              SButton(
                label: l10n.actionContinue,
                onPressed: () => _dismiss(context, ref),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
