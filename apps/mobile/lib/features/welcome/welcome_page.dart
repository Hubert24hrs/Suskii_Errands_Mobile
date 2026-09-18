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
  String _selectedCountry = 'NG';

  void _continue() {
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
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(SSpacing.xl),
          children: <Widget>[
            const SizedBox(height: SSpacing.xxl),
            Icon(
              Icons.local_shipping_outlined,
              size: 64,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: SSpacing.lg),
            Text(
              l10n.welcomeTitle,
              style: theme.textTheme.headlineMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: SSpacing.sm),
            Text(
              l10n.welcomeBody,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: SSpacing.xxl),
            Text(l10n.welcomeCountryLabel, style: theme.textTheme.titleMedium),
            const SizedBox(height: SSpacing.sm),
            packs.when(
              loading: () => const Column(
                children: <Widget>[SSkeletonListTile(), SSkeletonListTile()],
              ),
              error: (Object error, _) => SErrorState(
                title: l10n.stateErrorGeneric,
                message: localizedError(l10n, error),
                retryLabel: l10n.actionRetry,
                onRetry: () => ref.invalidate(_countryPacksProvider),
              ),
              data: (List<CountryPack> data) => Column(
                children: <Widget>[
                  for (final CountryPack pack in data)
                    _CountryTile(
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
                          : () => setState(
                              () => _selectedCountry = pack.countryCode,
                            ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: SSpacing.xl),
            Text(l10n.welcomeLanguageLabel, style: theme.textTheme.titleMedium),
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
              onSelectionChanged: (Set<String> selection) => ref
                  .read(localeControllerProvider.notifier)
                  .setLocale(Locale(selection.first)),
            ),
            const SizedBox(height: SSpacing.xxl),
            SButton(label: l10n.actionContinue, onPressed: _continue),
          ],
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
    final enabled = onTap != null;
    return Card(
      child: ListTile(
        onTap: onTap,
        enabled: enabled,
        leading: Icon(
          selected ? Icons.radio_button_checked : Icons.radio_button_off,
          color: selected ? theme.colorScheme.primary : null,
        ),
        title: Text(name),
        trailing: statusLabel == null
            ? null
            : Text(
                statusLabel!,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
      ),
    );
  }
}
