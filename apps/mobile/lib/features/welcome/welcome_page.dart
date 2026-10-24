import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:suskii_design/suskii_design.dart';
import 'package:suskii_l10n/suskii_l10n.dart';

import '../../app/providers.dart';
import '../../app/router.dart';

/// First-run screen: the language, then onboarding. There is no country to
/// pick (owner, 2026-10-24): a customer uses the country the phone is in
/// (`detectDeviceCountry`), confirmed by the server at bootstrap.
class WelcomePage extends ConsumerWidget {
  const WelcomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final locale = ref.watch(localeControllerProvider);

    return Scaffold(
      body: SAuroraBackground(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.symmetric(
              horizontal: SSpacing.gutter,
              vertical: SSpacing.xl,
            ),
            children: <Widget>[
              const SizedBox(height: SSpacing.xl),
              const Align(child: SBrandMark(size: 88)),
              const SizedBox(height: SSpacing.xl),
              Text(
                l10n.welcomeTitle,
                style: theme.textTheme.displaySmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: SSpacing.md),
              Text(
                l10n.welcomeBody,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: SSpacing.xxl),
              SSectionHeader(title: l10n.welcomeLanguageLabel),
              const SizedBox(height: SSpacing.sm),
              SegmentedButton<String>(
                segments: <ButtonSegment<String>>[
                  ButtonSegment<String>(
                    value: 'en',
                    label: Text(l10n.languageEnglish),
                  ),
                  ButtonSegment<String>(
                    value: 'pcm',
                    label: Text(l10n.languagePidgin),
                  ),
                ],
                selected: <String>{
                  locale?.languageCode ??
                      Localizations.localeOf(context).languageCode,
                },
                onSelectionChanged: (Set<String> selection) {
                  SHaptics.selection();
                  ref
                      .read(localeControllerProvider.notifier)
                      .setLocale(Locale(selection.first));
                },
              ),
              const SizedBox(height: SSpacing.xxl),
              SButton(
                key: const ValueKey<String>('welcome.continue'),
                label: l10n.actionContinue,
                icon: Icons.arrow_forward_rounded,
                onPressed: () {
                  ref.read(welcomeSeenProvider.notifier).set(true);
                  context.go(AppRoutes.onboarding);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
