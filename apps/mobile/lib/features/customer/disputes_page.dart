import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:suskii_design/suskii_design.dart';
import 'package:suskii_domain/suskii_domain.dart';
import 'package:suskii_l10n/suskii_l10n.dart';

import '../../app/error_l10n.dart';
import '../../app/labels.dart';
import '../../app/providers.dart';
import '../../app/router.dart';

/// Dispute center (M5): the user's disputes with SLA deadline, status and the
/// server-decided resolution (partial/full refund). Opening happens from the
/// job detail page via `showOpenDisputeSheet`.
class DisputesPage extends ConsumerWidget {
  const DisputesPage({super.key});

  String _resolutionLabel(AppLocalizations l10n, String key) => switch (key) {
    'disputeResolvedPartialRefund' => l10n.disputeResolvedPartialRefund,
    _ => key,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final locale = Localizations.localeOf(context).languageCode;
    final disputes = ref.watch(myDisputesProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.disputesTitle)),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(myDisputesProvider);
          await ref.read(myDisputesProvider.future);
        },
        child: disputes.when(
          loading: () => ListView(
            padding: const EdgeInsets.all(SSpacing.lg),
            children: const <Widget>[SSkeletonListTile(), SSkeletonListTile()],
          ),
          error: (Object error, _) => ListView(
            padding: const EdgeInsets.all(SSpacing.lg),
            children: <Widget>[
              SErrorState(
                title: l10n.stateErrorGeneric,
                message: localizedError(l10n, error),
                retryLabel: l10n.actionRetry,
                onRetry: () => ref.invalidate(myDisputesProvider),
              ),
            ],
          ),
          data: (List<Dispute> data) {
            if (data.isEmpty) {
              return ListView(
                padding: const EdgeInsets.all(SSpacing.lg),
                children: <Widget>[
                  SEmptyState(
                    icon: Icons.gavel_outlined,
                    title: l10n.disputesEmpty,
                  ),
                ],
              );
            }
            return ListView(
              padding: const EdgeInsets.all(SSpacing.lg),
              children: <Widget>[
                for (final Dispute dispute in data)
                  Card(
                    child: InkWell(
                      onTap: () => context.push(
                        AppRoutes.customerRequestDetailPath(dispute.jobId),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(SSpacing.lg),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Row(
                              children: <Widget>[
                                Expanded(
                                  child: Text(
                                    disputeReasonLabel(l10n, dispute.reasonKey),
                                    style: theme.textTheme.titleMedium,
                                  ),
                                ),
                                Chip(
                                  label: Text(
                                    disputeStatusLabel(l10n, dispute.status),
                                  ),
                                ),
                              ],
                            ),
                            Text(
                              MaterialLocalizations.of(context)
                                  .formatShortDate(dispute.createdAt),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            if ((dispute.status == DisputeStatus.open ||
                                    dispute.status == DisputeStatus.inReview) &&
                                dispute.slaDeadline != null) ...<Widget>[
                              const SizedBox(height: SSpacing.xs),
                              Text(
                                l10n.disputeSlaLabel(
                                  MaterialLocalizations.of(context)
                                      .formatShortDate(dispute.slaDeadline!),
                                ),
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                            if (dispute.resolutionNoteKey != null) ...<Widget>[
                              const SizedBox(height: SSpacing.xs),
                              Text(
                                _resolutionLabel(
                                  l10n,
                                  dispute.resolutionNoteKey!,
                                ),
                                style: theme.textTheme.bodyMedium,
                              ),
                            ],
                            if (dispute.refundAmount != null) ...<Widget>[
                              const SizedBox(height: SSpacing.xs),
                              Text(
                                '${l10n.disputeRefundLabel}: '
                                '${dispute.refundAmount!.format(locale: locale)}',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
