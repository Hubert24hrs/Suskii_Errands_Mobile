import 'package:flutter/material.dart';

import '../tokens/spacing.dart';
import 'motion.dart';

/// Design-system toast. Neutral by default, error styling when flagged; an
/// error also gives a warning haptic, so a refusal is felt as well as read.
void showSToast(BuildContext context, String message, {bool isError = false}) {
  final scheme = Theme.of(context).colorScheme;
  if (isError) SHaptics.warning();
  final foreground = isError
      ? scheme.onErrorContainer
      : scheme.onInverseSurface;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Row(
          children: <Widget>[
            Icon(
              isError
                  ? Icons.error_outline_rounded
                  : Icons.check_circle_rounded,
              size: 20,
              color: foreground,
            ),
            const SizedBox(width: SSpacing.md),
            Expanded(
              child: Text(
                message,
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: foreground),
              ),
            ),
          ],
        ),
        backgroundColor: isError
            ? scheme.errorContainer
            : scheme.inverseSurface,
      ),
    );
}

/// Confirmation dialog. Returns true when the user confirms.
Future<bool> showSConfirmDialog({
  required BuildContext context,
  required String title,
  required String message,
  required String confirmLabel,
  required String cancelLabel,
  bool destructive = false,
}) async {
  final scheme = Theme.of(context).colorScheme;
  final result = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      icon: destructive
          ? Icon(Icons.warning_amber_rounded, color: scheme.error, size: 32)
          : null,
      title: Text(title),
      content: Text(message),
      actionsPadding: const EdgeInsets.fromLTRB(
        SSpacing.lg,
        0,
        SSpacing.lg,
        SSpacing.lg,
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(cancelLabel),
        ),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: scheme.error,
                  foregroundColor: scheme.onError,
                )
              : null,
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}
