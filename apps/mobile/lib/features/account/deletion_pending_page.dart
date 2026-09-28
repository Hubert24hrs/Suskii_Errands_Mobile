import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:suskii_design/suskii_design.dart';
import 'package:suskii_l10n/suskii_l10n.dart';

import '../../app/error_l10n.dart';
import '../../app/idempotency_keys.dart';
import '../../app/providers.dart';
import '../../app/router.dart';

/// Shown on the first screen after signing back in to an account that is
/// scheduled for deletion. Keeping it cancels the deletion server-side
/// (`cancel_account_deletion`); continuing signs out again and lets the
/// grace period run. Either way the router moves on.
class DeletionPendingPage extends ConsumerStatefulWidget {
  const DeletionPendingPage({super.key});

  @override
  ConsumerState<DeletionPendingPage> createState() =>
      _DeletionPendingPageState();
}

class _DeletionPendingPageState extends ConsumerState<DeletionPendingPage> {
  static const String _intent = 'account.cancelDeletion';
  bool _busy = false;

  Future<void> _keep() async {
    final l10n = AppLocalizations.of(context);
    setState(() => _busy = true);
    final keys = ref.read(idempotencyKeysProvider);
    try {
      await ref
          .read(settingsRepositoryProvider)
          .cancelAccountDeletion(idempotencyKey: keys.forIntent(_intent));
      keys.done(_intent);
      ref.invalidate(bootstrapProvider);
      if (mounted) showSToast(context, l10n.deletionKept);
    } on Object catch (error) {
      if (mounted) {
        showSToast(context, localizedError(l10n, error), isError: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _leave() async {
    ref.read(deletionPromptDismissedProvider.notifier).set(true);
    ref.read(idempotencyKeysProvider).clear();
    await ref.read(authRepositoryProvider).signOut();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final when = ref
        .watch(bootstrapProvider)
        .value
        ?.accountDeletionScheduledFor;
    final date = when == null
        ? ''
        : MaterialLocalizations.of(context).formatMediumDate(when.toLocal());
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(SSpacing.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const Spacer(),
              Icon(
                Icons.hourglass_bottom_rounded,
                size: 72,
                color: theme.colorScheme.error,
              ),
              const SizedBox(height: SSpacing.xl),
              Text(
                l10n.deletionPendingTitle,
                style: theme.textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: SSpacing.md),
              Text(
                l10n.deletionPendingBody(date),
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const Spacer(),
              SButton(
                label: l10n.deletionPendingKeep,
                loading: _busy,
                onPressed: _busy ? null : _keep,
              ),
              const SizedBox(height: SSpacing.sm),
              SButton(
                label: l10n.deletionPendingContinue,
                variant: SButtonVariant.ghost,
                onPressed: _busy ? null : _leave,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
