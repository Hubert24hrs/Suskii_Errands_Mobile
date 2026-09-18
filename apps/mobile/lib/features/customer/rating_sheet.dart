import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_design/suskii_design.dart';
import 'package:suskii_l10n/suskii_l10n.dart';

import '../../app/error_l10n.dart';
import '../../app/labels.dart';
import '../../app/providers.dart';

const List<String> _tagKeys = <String>[
  'ratingTagPunctual',
  'ratingTagCareful',
  'ratingTagCommunicative',
  'ratingTagProfessional',
  'ratingTagSlow',
  'ratingTagRude',
];

/// Two-way rating sheet (M4), shown after a job is CONFIRMED and the user
/// has not rated yet. One rating per party per job, enforced server-side.
Future<void> showRatingSheet(BuildContext context, String jobId) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (BuildContext context) => RatingSheet(jobId: jobId),
  );
}

class RatingSheet extends ConsumerStatefulWidget {
  const RatingSheet({required this.jobId, super.key});

  final String jobId;

  @override
  ConsumerState<RatingSheet> createState() => _RatingSheetState();
}

class _RatingSheetState extends ConsumerState<RatingSheet> {
  int _stars = 0;
  final Set<String> _tags = <String>{};
  final TextEditingController _comment = TextEditingController();
  bool _busy = false;

  /// One key per rating intent (M3.14).
  String? _ratingKey;

  Future<void> _submit() async {
    if (_stars == 0) return;
    setState(() => _busy = true);
    try {
      _ratingKey ??= newIdempotencyKey();
      await ref
          .read(ratingRepositoryProvider)
          .submitRating(
            jobId: widget.jobId,
            stars: _stars,
            idempotencyKey: _ratingKey!,
            tagKeys: _tags.toList(),
            comment: _comment.text.trim().isEmpty ? null : _comment.text.trim(),
          );
      ref.invalidate(myRatingProvider(widget.jobId));
      if (mounted) {
        final l10n = AppLocalizations.of(context);
        Navigator.of(context).pop();
        showSToast(context, l10n.ratingThanks);
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
    _comment.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: SSpacing.lg,
          right: SSpacing.lg,
          bottom: MediaQuery.of(context).viewInsets.bottom + SSpacing.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(l10n.ratingTitle, style: theme.textTheme.titleLarge),
            const SizedBox(height: SSpacing.sm),
            Text(l10n.ratingPrompt, style: theme.textTheme.bodyMedium),
            const SizedBox(height: SSpacing.md),
            Center(
              child: SRatingInput(
                value: _stars,
                semanticLabel: l10n.ratingTitle,
                onChanged: (int v) => setState(() => _stars = v),
              ),
            ),
            const SizedBox(height: SSpacing.md),
            Wrap(
              spacing: SSpacing.sm,
              runSpacing: SSpacing.sm,
              children: <Widget>[
                for (final key in _tagKeys)
                  FilterChip(
                    label: Text(ratingTagLabel(l10n, key)),
                    selected: _tags.contains(key),
                    onSelected: (bool selected) => setState(() {
                      if (selected) {
                        _tags.add(key);
                      } else {
                        _tags.remove(key);
                      }
                    }),
                  ),
              ],
            ),
            const SizedBox(height: SSpacing.md),
            STextField(label: l10n.ratingCommentHint, controller: _comment),
            const SizedBox(height: SSpacing.lg),
            SButton(
              label: l10n.ratingSubmit,
              loading: _busy,
              onPressed: _busy || _stars == 0 ? null : _submit,
            ),
          ],
        ),
      ),
    );
  }
}
