import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_design/suskii_design.dart';
import 'package:suskii_domain/suskii_domain.dart';
import 'package:suskii_l10n/suskii_l10n.dart';

import '../../app/error_l10n.dart';
import '../../app/providers.dart';
import '../../app/router.dart';

/// Shared profile surface for both modes: identity, mode switch, verification
/// status, language/theme, demo offline toggle, version, sign out.
class ProfilePage extends ConsumerWidget {
  const ProfilePage({super.key});

  static const String _appVersion = '0.1.0';

  String _verificationLabel(AppLocalizations l10n, VerificationStatus status) =>
      switch (status) {
        VerificationStatus.unverified => l10n.verificationUnverified,
        VerificationStatus.pending => l10n.verificationPending,
        VerificationStatus.inReview => l10n.verificationInReview,
        VerificationStatus.verified => l10n.verificationVerified,
        VerificationStatus.rejected => l10n.verificationRejected,
        VerificationStatus.suspended => l10n.verificationSuspended,
        VerificationStatus.expired => l10n.verificationExpired,
      };

  Future<void> _switchMode(
    BuildContext context,
    WidgetRef ref,
    UserMode target,
  ) async {
    try {
      await ref.read(modeControllerProvider.notifier).switchMode(target);
      // Router redirect moves us into the other shell.
    } on Object catch (error) {
      if (context.mounted) {
        showSToast(
          context,
          localizedError(AppLocalizations.of(context), error),
          isError: true,
        );
      }
    }
  }

  Future<void> _signOut(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(authRepositoryProvider).signOut();
      // Router redirect returns to the auth route.
    } on Object catch (error) {
      if (context.mounted) {
        showSToast(
          context,
          localizedError(AppLocalizations.of(context), error),
          isError: true,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final user =
        ref.watch(authStateProvider).value?.user ??
        ref.watch(bootstrapProvider).value?.user;
    final mode = ref.watch(modeControllerProvider);
    final offline =
        ref.watch(connectivityProvider) == ConnectivityStatus.offline;
    final locale = ref.watch(localeControllerProvider);
    final themeMode = ref.watch(themeModeControllerProvider);
    final flavor = ref.watch(appConfigProvider).flavor.name;
    final providerVerified =
        user?.providerVerification == VerificationStatus.verified;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.profileTitle)),
      body: ListView(
        padding: const EdgeInsets.all(SSpacing.lg),
        children: <Widget>[
          if (user != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(SSpacing.lg),
                child: Row(
                  children: <Widget>[
                    CircleAvatar(
                      radius: 28,
                      child: Text(
                        user.displayName.substring(0, 1).toUpperCase(),
                        style: theme.textTheme.titleLarge,
                      ),
                    ),
                    const SizedBox(width: SSpacing.lg),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            user.displayName,
                            style: theme.textTheme.titleMedium,
                          ),
                          if (user.phoneE164 != null)
                            Text(
                              user.phoneE164!,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: SSpacing.lg),

          // Mode
          Text(l10n.profileCurrentMode, style: theme.textTheme.titleMedium),
          const SizedBox(height: SSpacing.sm),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(SSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    mode == UserMode.provider
                        ? l10n.modeProvider
                        : l10n.modeCustomer,
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: SSpacing.md),
                  if (mode == UserMode.provider)
                    SButton(
                      label: l10n.modeSwitchToCustomer,
                      variant: SButtonVariant.secondary,
                      onPressed: () => unawaited(
                        _switchMode(context, ref, UserMode.customer),
                      ),
                    )
                  else if (providerVerified)
                    SButton(
                      label: l10n.modeSwitchToProvider,
                      variant: SButtonVariant.secondary,
                      onPressed: () => unawaited(
                        _switchMode(context, ref, UserMode.provider),
                      ),
                    )
                  else ...<Widget>[
                    Text(
                      l10n.modeProviderLocked,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: SSpacing.md),
                    SButton(
                      label: l10n.modeProviderLockedAction,
                      variant: SButtonVariant.secondary,
                      onPressed: () =>
                          context.push(AppRoutes.providerOnboarding),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: SSpacing.lg),

          // Verification
          if (user != null) ...<Widget>[
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.badge_outlined),
              title: Text(l10n.profileCustomerVerification),
              trailing: Text(
                _verificationLabel(l10n, user.customerVerification),
                style: theme.textTheme.labelLarge,
              ),
              onTap: () => context.push(AppRoutes.verifyCustomer),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.verified_user_outlined),
              title: Text(l10n.profileProviderVerification),
              trailing: Text(
                _verificationLabel(l10n, user.providerVerification),
                style: theme.textTheme.labelLarge,
              ),
              onTap: () => context.push(
                user.providerVerification == VerificationStatus.unverified
                    ? AppRoutes.providerOnboarding
                    : AppRoutes.providerKyc,
              ),
            ),
            const SizedBox(height: SSpacing.lg),
          ],

          // M5: account surfaces
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.account_balance_wallet_outlined),
            title: Text(l10n.profileWallet),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push(AppRoutes.customerWallet),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.group_add_outlined),
            title: Text(l10n.profileReferrals),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push(AppRoutes.customerReferrals),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.local_offer_outlined),
            title: Text(l10n.profilePromos),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push(AppRoutes.customerPromos),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.gavel_outlined),
            title: Text(l10n.profileDisputes),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push(AppRoutes.customerDisputes),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.support_agent_outlined),
            title: Text(l10n.profileSupport),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push(AppRoutes.customerSupport),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.settings_outlined),
            title: Text(l10n.profileSettings),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push(AppRoutes.customerSettings),
          ),
          // M6: provider-only surfaces (router redirects /provider/* in
          // customer mode, so only offer them in provider mode).
          if (mode == UserMode.provider) ...[
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.handyman_outlined),
              title: Text(l10n.profileProviderTools),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push(AppRoutes.providerTools),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.business_center_outlined),
              title: Text(l10n.profileBusinessConsole),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push(AppRoutes.providerOrg),
            ),
          ],
          const SizedBox(height: SSpacing.lg),

          // Language
          Text(l10n.profileLanguage, style: theme.textTheme.titleMedium),
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
          const SizedBox(height: SSpacing.lg),

          // Theme
          Text(l10n.profileTheme, style: theme.textTheme.titleMedium),
          const SizedBox(height: SSpacing.sm),
          SegmentedButton<ThemeMode>(
            segments: <ButtonSegment<ThemeMode>>[
              ButtonSegment<ThemeMode>(
                value: ThemeMode.system,
                label: Text(l10n.profileThemeSystem),
              ),
              ButtonSegment<ThemeMode>(
                value: ThemeMode.light,
                label: Text(l10n.profileThemeLight),
              ),
              ButtonSegment<ThemeMode>(
                value: ThemeMode.dark,
                label: Text(l10n.profileThemeDark),
              ),
            ],
            selected: <ThemeMode>{themeMode},
            onSelectionChanged: (Set<ThemeMode> selection) => ref
                .read(themeModeControllerProvider.notifier)
                .setThemeMode(selection.first),
          ),
          const SizedBox(height: SSpacing.lg),

          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.profileSimulateOffline),
            value: offline,
            onChanged: (_) => ref
                .read(connectivityProvider.notifier)
                .toggleSimulatedOffline(),
          ),
          const Divider(),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.profileAppVersion),
            trailing: Text(
              '$_appVersion ($flavor)',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: SSpacing.lg),
          SButton(
            label: l10n.profileSignOut,
            variant: SButtonVariant.danger,
            icon: Icons.logout,
            onPressed: () => unawaited(_signOut(context, ref)),
          ),
        ],
      ),
    );
  }
}
