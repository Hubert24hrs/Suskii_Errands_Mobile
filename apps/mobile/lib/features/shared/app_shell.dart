import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_design/suskii_design.dart';
import 'package:suskii_l10n/suskii_l10n.dart';

import '../../app/providers.dart';

/// One destination of a mode shell.
class ShellDestination {
  const ShellDestination({
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

/// The frame both mode shells share: the offline banner above every tab and
/// a frosted navigation bar with a hairline top edge. Switching tabs gives a
/// selection haptic; re-selecting the current tab returns it to its root.
class AppShellScaffold extends ConsumerWidget {
  const AppShellScaffold({
    required this.navigationShell,
    required this.destinations,
    super.key,
  });

  final StatefulNavigationShell navigationShell;
  final List<ShellDestination> destinations;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final offline =
        ref.watch(connectivityProvider) == ConnectivityStatus.offline;
    final palette = context.sColors;

    return Scaffold(
      body: Column(
        children: <Widget>[
          if (offline) SOfflineBanner(label: l10n.stateOfflineBanner),
          Expanded(child: navigationShell),
        ],
      ),
      bottomNavigationBar: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: palette.glassBorder)),
        ),
        child: NavigationBar(
          selectedIndex: navigationShell.currentIndex,
          onDestinationSelected: (int index) {
            if (index != navigationShell.currentIndex) SHaptics.selection();
            navigationShell.goBranch(
              index,
              initialLocation: index == navigationShell.currentIndex,
            );
          },
          destinations: <NavigationDestination>[
            for (final ShellDestination d in destinations)
              NavigationDestination(
                icon: Icon(d.icon),
                selectedIcon: Icon(d.selectedIcon),
                label: d.label,
                tooltip: d.label,
              ),
          ],
        ),
      ),
    );
  }
}
