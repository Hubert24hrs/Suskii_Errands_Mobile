import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_design/suskii_design.dart';
import 'package:suskii_domain/suskii_domain.dart';
import 'package:suskii_l10n/suskii_l10n.dart';

import '../../app/error_l10n.dart';
import '../../app/labels.dart';
import '../../app/providers.dart';
import '../shared/job_card.dart';

/// Provider feed: online toggle, today's earnings, document reminders and
/// open requests nearby.
class ProviderFeedPage extends ConsumerStatefulWidget {
  const ProviderFeedPage({super.key});

  @override
  ConsumerState<ProviderFeedPage> createState() => _ProviderFeedPageState();
}

class _ProviderFeedPageState extends ConsumerState<ProviderFeedPage> {
  bool _toggling = false;

  Future<void> _setOnline(bool online) async {
    setState(() => _toggling = true);
    try {
      await ref
          .read(providerRepositoryProvider)
          .setOnline(online, idempotencyKey: newIdempotencyKey());
      ref.invalidate(providerHomeProvider);
    } on Object catch (error) {
      if (mounted) {
        showSToast(
          context,
          localizedError(AppLocalizations.of(context), error),
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _toggling = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final locale = Localizations.localeOf(context).languageCode;
    final summary = ref.watch(providerHomeProvider);
    final nearby = ref.watch(nearbyRequestsProvider);
    final categories =
        ref.watch(categoriesProvider).value ?? const <ServiceCategory>[];

    String categoryLabelFor(String categoryId) {
      for (final ServiceCategory category in categories) {
        if (category.id == categoryId) {
          return categoryLabel(l10n, category.labelKey);
        }
      }
      return l10n.catCustom;
    }

    return Scaffold(
      appBar: AppBar(title: Text(l10n.providerHomeTitle)),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(providerHomeProvider);
          await ref.read(providerHomeProvider.future);
        },
        child: ListView(
          padding: const EdgeInsets.all(SSpacing.lg),
          children: <Widget>[
            summary.when(
              loading: () => const Column(
                children: <Widget>[SSkeletonListTile(), SSkeletonListTile()],
              ),
              error: (Object error, _) => SErrorState(
                title: l10n.stateErrorGeneric,
                message: localizedError(l10n, error),
                retryLabel: l10n.actionRetry,
                onRetry: () => ref.invalidate(providerHomeProvider),
              ),
              data: (ProviderHomeSummary data) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  if (data.verificationStatus == VerificationStatus.pending ||
                      data.verificationStatus == VerificationStatus.inReview)
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.hourglass_top_outlined),
                        title: Text(l10n.providerVerificationPending),
                      ),
                    ),
                  Card(
                    child: SwitchListTile(
                      title: Text(
                        data.online
                            ? l10n.providerOnlineNow
                            : l10n.providerOfflineNow,
                      ),
                      secondary: Icon(
                        Icons.circle,
                        size: 14,
                        color: data.online
                            ? theme.colorScheme.primary
                            : theme.colorScheme.outline,
                      ),
                      value: data.online,
                      onChanged: _toggling
                          ? null
                          : (bool value) => unawaited(_setOnline(value)),
                    ),
                  ),
                  const SizedBox(height: SSpacing.sm),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(SSpacing.lg),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            l10n.providerTodayEarnings,
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: SSpacing.xs),
                          Text(
                            data.todayEarnings.format(locale: locale),
                            style: theme.textTheme.headlineMedium,
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (data.documentWarnings.isNotEmpty) ...<Widget>[
                    const SizedBox(height: SSpacing.lg),
                    Text(
                      l10n.feedDocWarnings,
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: SSpacing.sm),
                    for (final DocumentExpiryWarning warning
                        in data.documentWarnings)
                      Card(
                        child: ListTile(
                          leading: Icon(
                            Icons.warning_amber_outlined,
                            color: theme.colorScheme.error,
                          ),
                          title: Text(
                            l10n.providerDocExpiryWarning(
                              documentTypeLabel(l10n, warning.documentTypeKey),
                              warning.daysRemaining,
                            ),
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: SSpacing.lg),
            Text(
              l10n.providerNearbyRequests,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: SSpacing.sm),
            nearby.when(
              loading: () => const Column(
                children: <Widget>[SSkeletonListTile(), SSkeletonListTile()],
              ),
              error: (Object error, _) => SErrorState(
                title: l10n.stateErrorGeneric,
                message: localizedError(l10n, error),
                retryLabel: l10n.actionRetry,
                onRetry: () => ref.invalidate(nearbyRequestsProvider),
              ),
              data: (List<JobRequest> jobs) {
                if (jobs.isEmpty) {
                  return SEmptyState(
                    icon: Icons.explore_outlined,
                    title: l10n.feedNearbyEmpty,
                  );
                }
                return Column(
                  children: <Widget>[
                    for (final JobRequest job in jobs)
                      JobCard(
                        job: job,
                        categoryLabel: categoryLabelFor(job.categoryId),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
