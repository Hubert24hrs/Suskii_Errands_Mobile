import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:suskii_domain/suskii_domain.dart';
import 'package:suskii_l10n/suskii_l10n.dart';

import '../../app/device_location.dart';
import '../../app/providers.dart';
import '../shared/app_shell.dart';

/// Provider mode shell: Feed / Jobs / Earnings / Profile.
class ProviderShell extends StatelessWidget {
  const ProviderShell({required this.navigationShell, super.key});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return _OnlineHeartbeat(
      child: AppShellScaffold(
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
      ),
    );
  }
}

/// While the provider is online, their position goes to the server: matching
/// only considers a position younger than two minutes, so without this an
/// online provider is never told about a request. Foreground only — the app
/// declares no background location.
class _OnlineHeartbeat extends ConsumerStatefulWidget {
  const _OnlineHeartbeat({required this.child});

  final Widget child;

  @override
  ConsumerState<_OnlineHeartbeat> createState() => _OnlineHeartbeatState();
}

class _OnlineHeartbeatState extends ConsumerState<_OnlineHeartbeat> {
  /// Inside the two-minute matching window with room for one missed tick.
  static const Duration _interval = Duration(seconds: 45);

  Timer? _timer;

  @override
  void initState() {
    super.initState();
    ref.listenManual<AsyncValue<ProviderHomeSummary>>(
      providerHomeProvider,
      (_, next) => _sync(online: next.value?.online ?? false),
      fireImmediately: true,
    );
  }

  void _sync({required bool online}) {
    if (online && _timer == null) {
      unawaited(_tick());
      _timer = Timer.periodic(_interval, (_) => unawaited(_tick()));
    } else if (!online && _timer != null) {
      _timer!.cancel();
      _timer = null;
    }
  }

  Future<void> _tick() async {
    final reading = await ref.read(deviceLocationProvider).current();
    final point = reading.point;
    if (point == null || !mounted) return;
    try {
      await ref
          .read(trackingRepositoryProvider)
          .reportPosition(LiveFix(point: point));
    } on Object {
      // The next tick reports again; a missed one only narrows the window.
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
