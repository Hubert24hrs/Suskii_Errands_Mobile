import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:suskii_l10n/suskii_l10n.dart';

import '../shared/app_shell.dart';

/// Provider mode shell: Feed / Jobs / Earnings / Profile.
class ProviderShell extends StatelessWidget {
  const ProviderShell({required this.navigationShell, super.key});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AppShellScaffold(
      navigationShell: navigationShell,
      destinations: <ShellDestination>[
        ShellDestination(
          icon: Icons.explore_outlined,
          selectedIcon: Icons.explore_rounded,
          label: l10n.navFeed,
        ),
        ShellDestination(
          icon: Icons.work_outline_rounded,
          selectedIcon: Icons.work_rounded,
          label: l10n.navJobs,
        ),
        ShellDestination(
          icon: Icons.account_balance_wallet_outlined,
          selectedIcon: Icons.account_balance_wallet_rounded,
          label: l10n.navEarnings,
        ),
        ShellDestination(
          icon: Icons.person_outline_rounded,
          selectedIcon: Icons.person_rounded,
          label: l10n.navProfile,
        ),
      ],
    );
  }
}
