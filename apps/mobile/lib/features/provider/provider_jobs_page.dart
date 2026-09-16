import 'package:flutter/material.dart';
import 'package:suskii_design/suskii_design.dart';
import 'package:suskii_l10n/suskii_l10n.dart';

/// Provider's accepted/assigned jobs. No provider-scoped job-list method
/// exists on the repository contract yet (M6 provider tools), so M1 shows
/// the empty state.
class ProviderJobsPage extends StatelessWidget {
  const ProviderJobsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.navJobs)),
      body: SEmptyState(
        icon: Icons.work_outline,
        title: l10n.providerJobsEmpty,
      ),
    );
  }
}
