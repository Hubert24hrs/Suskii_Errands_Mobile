import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_design/suskii_design.dart';
import 'package:suskii_l10n/suskii_l10n.dart';

import '../../app/error_l10n.dart';
import '../../app/labels.dart';
import '../../app/providers.dart';

const List<String> _reasonKeys = <String>[
  'disputeReasonNotDelivered',
  'disputeReasonDamaged',
  'disputeReasonLate',
  'disputeReasonOther',
];

/// Open-dispute sheet (M5), shown from the job detail page while the job is
/// in a disputable state. Opening freezes the payout server-side.
Future<void> showOpenDisputeSheet(BuildContext context, String jobId) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (BuildContext context) => OpenDisputeSheet(jobId: jobId),
  );
}

class OpenDisputeSheet extends ConsumerStatefulWidget {
  const OpenDisputeSheet({required this.jobId, super.key});

  final String jobId;

  @override
  ConsumerState<OpenDisputeSheet> createState() => _OpenDisputeSheetState();
}

class _OpenDisputeSheetState extends ConsumerState<OpenDisputeSheet> {
  String _reasonKey = _reasonKeys.first;
  final TextEditingController _details = TextEditingController();
  bool _busy = false;

  /// One key per dispute intent (M3.14).
  String? _disputeKey;

  Future<void> _submit() async {
    setState(() => _busy = true);
    try {
      _disputeKey ??= newIdempotencyKey();
      final details = _details.text.trim();
      await ref
          .read(disputeRepositoryProvider)
          .openDispute(
            jobId: widget.jobId,
            reasonKey: _reasonKey,
            idempotencyKey: _disputeKey!,
            details: details.isEmpty ? null : details,
          );
      _disputeKey = null;
      ref
        ..invalidate(myDisputesProvider)
        ..invalidate(disputeForJobProvider(widget.jobId));
      if (mounted) {
        final l10n = AppLocalizations.of(context);
        Navigator.of(context).pop();
        showSToast(context, l10n.disputeOpenedToast);
      }
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
  void dispose() {
    _details.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.only(
          left: SSpacing.lg,
          right: SSpacing.lg,
          bottom: MediaQuery.of(context).viewInsets.bottom + SSpacing.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(l10n.disputeOpenCta, style: theme.textTheme.titleLarge),
            const SizedBox(height: SSpacing.sm),
            Text(l10n.disputeReasonLabel, style: theme.textTheme.labelLarge),
            RadioGroup<String>(
              groupValue: _reasonKey,
              onChanged: (String? value) {
                if (value != null) setState(() => _reasonKey = value);
              },
              child: Column(
                children: <Widget>[
                  for (final key in _reasonKeys)
                    RadioListTile<String>(
                      value: key,
                      title: Text(disputeReasonLabel(l10n, key)),
                      contentPadding: EdgeInsets.zero,
                    ),
                ],
              ),
            ),
            STextField(
              label: l10n.disputeDetailsHint,
              controller: _details,
              maxLines: 3,
            ),
            const SizedBox(height: SSpacing.xs),
            Text(
              l10n.disputeEvidenceHint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: SSpacing.lg),
            SButton(
              label: l10n.disputeSubmitCta,
              variant: SButtonVariant.danger,
              loading: _busy,
              onPressed: _busy ? null : _submit,
            ),
          ],
        ),
      ),
    );
  }
}
