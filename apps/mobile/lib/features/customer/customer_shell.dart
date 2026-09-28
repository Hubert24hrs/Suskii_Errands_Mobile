import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:suskii_l10n/suskii_l10n.dart';

import '../shared/app_shell.dart';

/// Customer mode shell: Home / Requests / Messages / Profile.
class CustomerShell extends StatelessWidget {
  const CustomerShell({required this.navigationShell, super.key});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AppShellScaffold(
      navigationShell: navigationShell,
      destinations: <ShellDestination>[
        ShellDestination(
          icon: Icons.home_outlined,
          selectedIcon: Icons.home_rounded,
          label: l10n.navHome,
        ),
        ShellDestination(
          icon: Icons.receipt_long_outlined,
          selectedIcon: Icons.receipt_long_rounded,
          label: l10n.navRequests,
        ),
        ShellDestination(
          icon: Icons.chat_bubble_outline_rounded,
          selectedIcon: Icons.chat_bubble_rounded,
          label: l10n.navMessages,
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
