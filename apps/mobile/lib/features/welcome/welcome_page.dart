import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:suskii_design/suskii_design.dart';
import 'package:suskii_domain/suskii_domain.dart';
import 'package:suskii_l10n/suskii_l10n.dart';

import '../../app/error_l10n.dart';
import '../../app/providers.dart';
import '../../app/router.dart';

/// Countries the UI offers on first run. Status (live/beta/disabled) comes
/// from the server-style country pack, never hardcoded here.
const List<String> _welcomeCountryCodes = <String>[
  'NG',
  'KE',
  'GH',
  'ZA',
  'UG',
];

final _countryPacksProvider = FutureProvider<List<CountryPack>>((ref) {
  final catalog = ref.watch(catalogRepositoryProvider);
  return Future.wait(_welcomeCountryCodes.map(catalog.getCountryPack));
});

String _countryName(AppLocalizations l10n, String code) => switch (code) {
  'NG' => l10n.countryNg,
  'KE' => l10n.countryKe,
  'GH' => l10n.countryGh,
  'ZA' => l10n.countryZa,
  'UG' => l10n.countryUg,
  _ => code,
};

/// First-run screen: country + language selection, then onboarding.
class WelcomePage extends ConsumerStatefulWidget {
  const WelcomePage({super.key});

  @override
  ConsumerState<WelcomePage> createState() => _WelcomePageState();
}

class _WelcomePageState extends ConsumerState<WelcomePage> {
  late String _selectedCountry = ref.read(selectedCountryProvider) ?? 'NG';

  void _continue() {
    // The choice is the bootstrap hint and the sign-up metadata: the server
    // creates the profile in this country (audit 2026-09-27 Y.14/Y.27).
    ref.read(selectedCountryProvider.notifier).set(_selectedCountry);
    ref.read(welcomeSeenProvider.notifier).set(true);
    context.go(AppRoutes.onboarding);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final packs = ref.watch(_countryPacksProvider);
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
              const Align(child: SBrandMark()),
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
              SSectionHeader(title: l10n.welcomeCountryLabel),
              const SizedBox(height: SSpacing.sm),
              packs.when(
                loading: () => const Column(
                  children: <Widget>[
                    SSkeletonCard(height: 64),
                    SSkeletonCard(height: 64),
                  ],
                ),
                error: (Object error, _) => SErrorState(
                  title: l10n.stateErrorGeneric,
                  message: localizedError(l10n, error),
                  retryLabel: l10n.actionRetry,
                  onRetry: () => ref.invalidate(_countryPacksProvider),
                ),
                data: (List<CountryPack> data) => Column(
                  children: <Widget>[
                    for (final (int i, CountryPack pack) in data.indexed)
                      SFadeSlideIn(
                        index: i,
                        child: _CountryTile(
                          pack: pack,
                          name: _countryName(l10n, pack.countryCode),
                          statusLabel: switch (pack.status) {
                            CountryStatus.live => null,
                            CountryStatus.beta => l10n.countryStatusBeta,
                            CountryStatus.disabled => l10n.countryStatusSoon,
                          },
                          selected: _selectedCountry == pack.countryCode,
                          onTap: pack.status == CountryStatus.disabled
                              ? null
                              : () {
                                  SHaptics.selection();
                                  setState(
                                    () => _selectedCountry = pack.countryCode,
                                  );
                                },
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: SSpacing.xl),
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
                onPressed: _continue,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CountryTile extends StatelessWidget {
  const _CountryTile({
    required this.pack,
    required this.name,
    required this.selected,
    this.statusLabel,
    this.onTap,
  });

  final CountryPack pack;
  final String name;
  final String? statusLabel;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final enabled = onTap != null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: SSpacing.xs),
      child: SPressable(
        enabled: enabled,
        child: AnimatedContainer(
          duration: SMotion.of(context, SMotion.fast),
          decoration: BoxDecoration(
            color: selected
                ? scheme.primary.withValues(alpha: 0.12)
                : context.sColors.surfaceRaised,
            borderRadius: SRadius.borderLg,
            border: Border.all(
              color: selected ? scheme.primary : scheme.outlineVariant,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Semantics(
            selected: selected,
            button: true,
            // The tile's own Material, so its ink shows above the fill.
            child: Material(
              type: MaterialType.transparency,
              child: ListTile(
                onTap: onTap,
                enabled: enabled,
                shape: const RoundedRectangleBorder(
                  borderRadius: SRadius.borderLg,
                ),
                leading: Text(
                  pack.countryCode,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: selected ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                ),
                title: Text(name, style: theme.textTheme.titleMedium),
                trailing: selected
                    ? Icon(Icons.check_circle_rounded, color: scheme.primary)
                    : statusLabel == null
                    ? null
                    : Text(statusLabel!, style: theme.textTheme.labelSmall),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
