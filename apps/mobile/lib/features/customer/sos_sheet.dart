import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_design/suskii_design.dart';
import 'package:suskii_domain/suskii_domain.dart';
import 'package:suskii_l10n/suskii_l10n.dart';

import '../../app/error_l10n.dart';
import '../../app/labels.dart';
import '../../app/providers.dart';

/// SOS bottom sheet (M4): confirm → the SERVER alerts operations, the city
/// security partner and trusted contacts. While an alert is active the sheet
/// shows the country pack's local emergency numbers and the live-trip share
/// action.
Future<void> showSosSheet(BuildContext context, String jobId) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (BuildContext context) => SosSheet(jobId: jobId),
  );
}

class SosSheet extends ConsumerStatefulWidget {
  const SosSheet({required this.jobId, super.key});

  final String jobId;

  @override
  ConsumerState<SosSheet> createState() => _SosSheetState();
}

class _SosSheetState extends ConsumerState<SosSheet> {
  bool _busy = false;

  /// One key per SOS intent (M3.14).
  String? _sosKey;
  String? _shareKey;

  Future<void> _trigger() => _run(() async {
    _sosKey ??= newIdempotencyKey();
    await ref
        .read(safetyRepositoryProvider)
        .triggerSos(jobId: widget.jobId, idempotencyKey: _sosKey!);
  });

  Future<void> _shareTrip() => _run(() async {
    _shareKey ??= newIdempotencyKey();
    final share = await ref
        .read(safetyRepositoryProvider)
        .createTripShareLink(widget.jobId, idempotencyKey: _shareKey!);
    // Same rule as the tracking page: the share succeeded even if the clipboard refused.
    var copied = true;
    try {
      await Clipboard.setData(ClipboardData(text: share.url));
    } on Object {
      copied = false;
    }
    if (mounted) {
      showSToast(
        context,
        copied ? AppLocalizations.of(context).sosTripShared : share.url,
      );
    }
  });

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } on Object catch (error) {
      if (mounted) {
        showSToast(
          context,
          localizedError(AppLocalizations.of(context), error),
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final sos = ref.watch(activeSosProvider(widget.jobId));
    final boot = ref.watch(bootstrapProvider).value;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: SSpacing.lg,
          right: SSpacing.lg,
          bottom: MediaQuery.of(context).viewInsets.bottom + SSpacing.lg,
        ),
        child: sos.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(SSpacing.xl),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (Object error, _) => Text(
            localizedError(l10n, error),
            style: theme.textTheme.bodyMedium,
          ),
          data: (SosAlert? active) {
            if (active == null) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(l10n.sosTitle, style: theme.textTheme.titleLarge),
                  const SizedBox(height: SSpacing.md),
                  Text(l10n.sosConfirmBody, style: theme.textTheme.bodyMedium),
                  const SizedBox(height: SSpacing.lg),
                  SButton(
                    label: l10n.sosSend,
                    variant: SButtonVariant.danger,
                    icon: Icons.sos_outlined,
                    loading: _busy,
                    onPressed: _busy ? null : _trigger,
                  ),
                ],
              );
            }
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Icon(Icons.sos, color: theme.colorScheme.error),
                    const SizedBox(width: SSpacing.sm),
                    Text(
                      l10n.sosActiveTitle,
                      style: theme.textTheme.titleLarge,
                    ),
                  ],
                ),
                const SizedBox(height: SSpacing.md),
                Text(
                  l10n.sosActiveBody(active.trustedContactsNotified),
                  style: theme.textTheme.bodyMedium,
                ),
                if (boot != null &&
                    boot.countryPack.emergencyNumbers.isNotEmpty) ...<Widget>[
                  const SizedBox(height: SSpacing.lg),
                  Text(
                    l10n.sosEmergencyNumbers,
                    style: theme.textTheme.titleSmall,
                  ),
                  for (final number in boot.countryPack.emergencyNumbers)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.phone_in_talk_outlined),
                      title: Text(emergencyNumberLabel(l10n, number.labelKey)),
                      trailing: Text(
                        number.number,
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                ],
                const SizedBox(height: SSpacing.md),
                SButton(
                  label: l10n.sosShareTrip,
                  variant: SButtonVariant.secondary,
                  icon: Icons.share_outlined,
                  loading: _busy,
                  onPressed: _busy ? null : _shareTrip,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
