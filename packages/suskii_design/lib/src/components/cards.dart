import 'package:flutter/material.dart';
import 'package:suskii_domain/suskii_domain.dart';

import '../tokens/radius.dart';
import '../tokens/spacing.dart';
import 'buttons.dart';
import 'chips.dart';
import 'countdown.dart';

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

  /// Server − device clock offset for the expiry countdown (offer deadlines
  /// are server timestamps).
  final Duration? clockOffset;

  final VoidCallback? onAccept;
  final VoidCallback? onCounter;
  final VoidCallback? onDecline;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
                Expanded(
                  child: Text(
                    offer.providerName,
                    style: theme.textTheme.titleMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                STrustLevelChip(
                  level: offer.providerTrustLevel,
                  label: offer.providerTrustLevel.name.toUpperCase(),
                ),
              ],
            ),
            const SizedBox(height: SSpacing.xs),
            Row(
              children: <Widget>[
                const Icon(Icons.star_rounded, size: 16),
                const SizedBox(width: SSpacing.xs),
                Text(
                  offer.providerRating.toStringAsFixed(1),
                  style: theme.textTheme.bodySmall,
                ),
                if (offer.distanceMeters != null) ...<Widget>[
                  const SizedBox(width: SSpacing.md),
                  const Icon(Icons.place_outlined, size: 16),
                  const SizedBox(width: SSpacing.xs),
                  Text(
                    '${(offer.distanceMeters! / 1000).toStringAsFixed(1)} km',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ],
            ),
            const SizedBox(height: SSpacing.md),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Expanded(
                  child: Text(
                    offer.amount.format(),
                    style: theme.textTheme.headlineSmall,
                  ),
                ),
                if (offer.expiresAt != null)
                  SCountdownTimer(
                    deadline: offer.expiresAt!,
                    clockOffset: clockOffset,
                  ),
              ],
            ),
            if (offer.message != null && offer.message!.isNotEmpty) ...<Widget>[
              const SizedBox(height: SSpacing.sm),
              Text(offer.message!, style: theme.textTheme.bodySmall),
            ],
            const SizedBox(height: SSpacing.md),
            Row(
              children: <Widget>[
                Expanded(
                  child: SButton(
                    label: acceptLabel,
                    onPressed: actionable ? onAccept : null,
                  ),
                ),
                const SizedBox(width: SSpacing.sm),
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
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: SRadius.borderMd,
        child: Padding(
          padding: const EdgeInsets.all(SSpacing.lg),
          child: Row(
            children: <Widget>[
              CircleAvatar(
                radius: 24,
                child: Text(
                  (profile.displayName ?? '?').substring(0, 1).toUpperCase(),
                ),
              ),
              const SizedBox(width: SSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      profile.businessName ?? profile.displayName ?? '',
                      style: theme.textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: SSpacing.xs),
                    Text(
                      '★ ${profile.rating.toStringAsFixed(1)} · '
                      '${profile.completedJobs} jobs',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              if (profile.online)
                Icon(Icons.circle, size: 10, color: theme.colorScheme.primary),
            ],
          ),
        ),
      ),
    );
  }
}
