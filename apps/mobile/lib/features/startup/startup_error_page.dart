import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:suskii_design/suskii_design.dart';
import 'package:suskii_l10n/suskii_l10n.dart';

import '../../app/error_l10n.dart';
import '../../app/providers.dart';

/// Bootstrap failed (offline, disabled country, force update…). Shows the
/// localized cause and re-runs bootstrap on retry.
class StartupErrorPage extends ConsumerWidget {
  const StartupErrorPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final boot = ref.watch(bootstrapProvider);
    final message = boot.maybeWhen(
      error: (Object error, _) => localizedError(l10n, error),
      orElse: () => l10n.errUnknown,
    );
    return Scaffold(
      body: SafeArea(
        child: SErrorState(
          title: l10n.stateErrorGeneric,
          message: message,
          retryLabel: l10n.actionRetry,
          onRetry: () => ref.invalidate(bootstrapProvider),
        ),
      ),
    );
  }
}
