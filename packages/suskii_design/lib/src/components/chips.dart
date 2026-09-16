import 'package:flutter/material.dart';
import 'package:suskii_domain/suskii_domain.dart';

import '../tokens/radius.dart';
import '../tokens/spacing.dart';

/// Colored chip for a [JobStatus]. Colors come from the theme's semantic
/// palette; the label text is supplied by the caller (localized).
class SStatusChip extends StatelessWidget {
  const SStatusChip({required this.status, required this.label, super.key});

  final JobStatus status;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (bg, fg) = switch (status) {
      JobStatus.draft ||
      JobStatus.published ||
      JobStatus.offersReceived ||
      JobStatus.negotiating => (
        scheme.secondaryContainer,
        scheme.onSecondaryContainer,
      ),
      JobStatus.agreed ||
      JobStatus.paymentPending ||
      JobStatus.paidHeld ||
      JobStatus.assigned => (
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
      ),
      JobStatus.enRoute || JobStatus.arrived || JobStatus.inProgress => (
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
      ),
      JobStatus.completedByProvider ||
      JobStatus.confirmed ||
      JobStatus.settlementPending ||
      JobStatus.settled ||
      JobStatus.closed => (
        scheme.secondaryContainer,
        scheme.onSecondaryContainer,
      ),
      JobStatus.disputed => (scheme.errorContainer, scheme.onErrorContainer),
      JobStatus.cancelled || JobStatus.expired || JobStatus.refunded => (
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
      ),
    };
    return _ChipBase(label: label, background: bg, foreground: fg);
  }
}

/// Trust level badge: NEW / VERIFIED / TRUSTED / ELITE.
class STrustLevelChip extends StatelessWidget {
  const STrustLevelChip({required this.level, required this.label, super.key});

  final TrustLevel level;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (bg, fg, icon) = switch (level) {
      TrustLevel.new_ => (
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
        Icons.person_outline,
      ),
      TrustLevel.verified => (
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
        Icons.verified_outlined,
      ),
      TrustLevel.trusted => (
        scheme.secondaryContainer,
        scheme.onSecondaryContainer,
        Icons.shield_outlined,
      ),
      TrustLevel.elite => (
        scheme.tertiaryContainer,
        scheme.onTertiaryContainer,
        Icons.workspace_premium_outlined,
      ),
    };
    return _ChipBase(label: label, background: bg, foreground: fg, icon: icon);
  }
}

class _ChipBase extends StatelessWidget {
  const _ChipBase({
    required this.label,
    required this.background,
    required this.foreground,
    this.icon,
  });

  final String label;
  final Color background;
  final Color foreground;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SSpacing.sm,
        vertical: SSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: SRadius.borderSm,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 14, color: foreground),
            const SizedBox(width: SSpacing.xs),
          ],
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall
                ?.copyWith(color: foreground),
          ),
        ],
      ),
    );
  }
}
