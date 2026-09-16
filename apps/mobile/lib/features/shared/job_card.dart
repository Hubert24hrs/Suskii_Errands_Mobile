import 'package:flutter/material.dart';
import 'package:suskii_design/suskii_design.dart';
import 'package:suskii_domain/suskii_domain.dart';
import 'package:suskii_l10n/suskii_l10n.dart';

import '../../app/labels.dart';

/// Compact job/request card shared by the customer home, requests history,
/// and provider feed surfaces. All money values arrive pre-computed from the
/// server — this widget only formats them for display.
class JobCard extends StatelessWidget {
  const JobCard({
    required this.job,
    required this.categoryLabel,
    super.key,
    this.onTap,
  });

  final JobRequest job;

  /// Already-localized category label (resolved by the caller, which owns
  /// the category list).
  final String categoryLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final locale = Localizations.localeOf(context).languageCode;
    final price = job.agreedPrice ?? job.preferredPrice;

    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: SRadius.borderMd,
        child: Padding(
          padding: const EdgeInsets.all(SSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      categoryLabel,
                      style: theme.textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  SStatusChip(
                    status: job.status,
                    label: jobStatusLabel(l10n, job.status),
                  ),
                ],
              ),
              const SizedBox(height: SSpacing.sm),
              Text(
                job.description,
                style: theme.textTheme.bodyMedium,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: SSpacing.sm),
              Row(
                children: <Widget>[
                  Icon(
                    Icons.place_outlined,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: SSpacing.xs),
                  Expanded(
                    child: Text(
                      job.pickup.label,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (price != null)
                    Text(
                      price.format(locale: locale),
                      style: theme.textTheme.titleMedium,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
