import 'package:flutter/material.dart';
import 'package:suskii_domain/suskii_domain.dart';

import '../tokens/colors.dart';
import '../tokens/radius.dart';
import '../tokens/spacing.dart';
import 'buttons.dart';
import 'chips.dart';
import 'countdown.dart';
import 'motion.dart';

/// Initial for an avatar, safe for an empty or whitespace-only name.
String _initial(String? name) {
  final trimmed = name?.trim() ?? '';
  return trimmed.isEmpty ? '' : trimmed.characters.first.toUpperCase();
}

/// A circular avatar with the brand gradient ring. Shows the person icon
/// when there is no name to take an initial from.
class SAvatar extends StatelessWidget {
  const SAvatar({super.key, this.name, this.size = 48});

  final String? name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final palette = context.sColors;
    final scheme = Theme.of(context).colorScheme;
    final initial = _initial(name);
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(colors: palette.gradient),
        ),
        child: CircleAvatar(
          backgroundColor: scheme.surfaceContainerHighest,
          foregroundColor: scheme.onSurface,
          child: initial.isEmpty
              ? Icon(Icons.person_rounded, size: size * 0.5)
              : Text(initial, style: Theme.of(context).textTheme.titleMedium),
        ),
      ),
    );
  }
}

/// Live offer card on the customer's offers board. All money values are
/// pre-computed by the server; this widget only formats and renders them.
class SOfferCard extends StatelessWidget {
  const SOfferCard({
    required this.offer,
    required this.acceptLabel,
    required this.counterLabel,
    required this.declineLabel,
    required this.etaLabel,
    super.key,
    this.trustLabel,
    this.distanceLabel,
    this.clockOffset,
    this.onAccept,
    this.onCounter,
    this.onDecline,
  });

  final Offer offer;
  final String acceptLabel;
  final String counterLabel;
  final String declineLabel;
  final String etaLabel;

  /// Localized trust level ("Verified"); the chip is omitted when null.
  final String? trustLabel;

  /// Localized distance ("2.4 km away"); omitted when null.
  final String? distanceLabel;

  /// Server − device clock offset for the expiry countdown (offer deadlines
  /// are server timestamps).
  final Duration? clockOffset;

  final VoidCallback? onAccept;
  final VoidCallback? onCounter;
  final VoidCallback? onDecline;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final actionable =
        offer.status == OfferStatus.pending ||
        offer.status == OfferStatus.countered;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(SSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                SAvatar(name: offer.providerName, size: 44),
                const SizedBox(width: SSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        offer.providerName,
                        style: theme.textTheme.titleMedium,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: SSpacing.xxs),
                      Wrap(
                        spacing: SSpacing.md,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: <Widget>[
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Icon(
                                Icons.star_rounded,
                                size: 16,
                                color: context.sColors.warning,
                              ),
                              const SizedBox(width: SSpacing.xxs),
                              Text(
                                offer.providerRating.toStringAsFixed(1),
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                          ),
                          if (distanceLabel != null)
                            Text(
                              distanceLabel!,
                              style: theme.textTheme.bodySmall,
                            ),
                          if (etaLabel.isNotEmpty)
                            Text(etaLabel, style: theme.textTheme.bodySmall),
                        ],
                      ),
                    ],
                  ),
                ),
                if (trustLabel != null)
                  STrustLevelChip(
                    level: offer.providerTrustLevel,
                    label: trustLabel!,
                  ),
              ],
            ),
            const SizedBox(height: SSpacing.lg),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Expanded(
                  child: Text(
                    offer.amount.format(),
                    style: theme.textTheme.headlineMedium,
                  ),
                ),
                if (offer.expiresAt != null && actionable)
                  SCountdownTimer(
                    deadline: offer.expiresAt!,
                    clockOffset: clockOffset,
                  ),
              ],
            ),
            if (offer.message != null && offer.message!.isNotEmpty) ...<Widget>[
              const SizedBox(height: SSpacing.sm),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(SSpacing.md),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHigh,
                  borderRadius: SRadius.borderMd,
                ),
                child: Text(offer.message!, style: theme.textTheme.bodyMedium),
              ),
            ],
            const SizedBox(height: SSpacing.lg),
            SButton(
              label: acceptLabel,
              icon: Icons.check_rounded,
              onPressed: actionable ? onAccept : null,
            ),
            const SizedBox(height: SSpacing.sm),
            Row(
              children: <Widget>[
                Expanded(
                  child: SButton(
                    label: counterLabel,
                    variant: SButtonVariant.secondary,
                    onPressed: actionable ? onCounter : null,
                  ),
                ),
                const SizedBox(width: SSpacing.sm),
                Expanded(
                  child: SButton(
                    label: declineLabel,
                    variant: SButtonVariant.ghost,
                    onPressed: actionable ? onDecline : null,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Compact provider summary card (search results, favorites, rebook flow).
class SProviderCard extends StatelessWidget {
  const SProviderCard({
    required this.profile,
    required this.statsLabel,
    super.key,
    this.onTap,
  });

  final ProviderProfile profile;

  /// Pre-formatted, localized stats line, e.g. "★ 4.9 · 123 jobs".
  final String statsLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = profile.businessName ?? profile.displayName ?? '';
    return SPressable(
      enabled: onTap != null,
      child: Card(
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(SSpacing.lg),
            child: Row(
              children: <Widget>[
                SAvatar(name: name),
                const SizedBox(width: SSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        name,
                        style: theme.textTheme.titleMedium,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: SSpacing.xs),
                      Text(statsLabel, style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
                if (profile.online)
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: context.sColors.success,
                      shape: BoxShape.circle,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
