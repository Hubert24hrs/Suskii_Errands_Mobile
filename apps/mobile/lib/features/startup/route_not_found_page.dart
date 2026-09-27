import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:suskii_design/suskii_design.dart';
import 'package:suskii_l10n/suskii_l10n.dart';

/// Where a link to a page that does not exist lands: an explanation and a
/// way back, in the user's language.
class RouteNotFoundPage extends StatelessWidget {
  const RouteNotFoundPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          child: SEmptyState(
            icon: Icons.explore_off_outlined,
            title: l10n.errNotFound,
            actionLabel: l10n.navHome,
            onAction: () => context.go('/'),
          ),
        ),
      ),
    );
  }
}
