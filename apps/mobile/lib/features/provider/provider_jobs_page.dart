import 'dart:async';

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
import '../shared/job_card.dart';

/// Provider's jobs (M8.6): active assignments from `watchMyJobs` with a
/// next-action hint per status, plus the first page of terminal-job history.
/// Rows open the job-execution page.
class ProviderJobsPage extends ConsumerWidget {
  const ProviderJobsPage({super.key});

  /// Localized hint for the provider's next action in [status], or null when
  /// nothing is actionable right now.
  static String? nextActionLabel(AppLocalizations l10n, JobStatus status) =>
      switch (status) {
        JobStatus.paidHeld || JobStatus.assigned => l10n.jobActionStartJourney,
        JobStatus.enRoute => l10n.jobActionArrived,
        JobStatus.arrived => l10n.jobActionVerifyPickupPin,
        JobStatus.inProgress => l10n.jobActionMarkComplete,
        JobStatus.completedByProvider => l10n.jobWaitingCustomerConfirmation,
        _ => null,
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final active = ref.watch(providerJobsProvider);
    final history = ref.watch(providerJobsHistoryProvider);
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
      appBar: AppBar(title: Text(l10n.myJobsTitle)),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(providerJobsHistoryProvider);
            await ref.read(providerJobsHistoryProvider.future);
          },
          child: ListView(
            padding: const EdgeInsets.all(SSpacing.lg),
            children: <Widget>[
              active.when(
                loading: () => const Column(
                  children: <Widget>[SSkeletonListTile(), SSkeletonListTile()],
                ),
                error: (Object error, _) => SErrorState(
                  title: l10n.stateErrorGeneric,
                  message: localizedError(l10n, error),
                  retryLabel: l10n.actionRetry,
                  onRetry: () => ref.invalidate(providerJobsProvider),
                ),
                data: (List<JobRequest> jobs) {
                  if (jobs.isEmpty) {
                    return SEmptyState(
                      icon: Icons.work_outline,
                      title: l10n.providerJobsEmpty,
                    );
                  }
                  return Column(
                    children: <Widget>[
                      for (final JobRequest job in jobs) ...<Widget>[
                        JobCard(
                          job: job,
                          categoryLabel: categoryLabelFor(job.categoryId),
                          onTap: () => unawaited(
                            context.push(
                              AppRoutes.providerJobExecutionPath(job.id),
                            ),
                          ),
                        ),
                        if (nextActionLabel(l10n, job.status) != null)
                          Padding(
                            padding: const EdgeInsets.only(
                              left: SSpacing.md,
                              bottom: SSpacing.sm,
                            ),
                            child: Row(
                              children: <Widget>[
                                Icon(
                                  Icons.arrow_forward_rounded,
                                  size: 16,
                                  color: theme.colorScheme.primary,
                                ),
                                const SizedBox(width: SSpacing.xs),
                                Expanded(
                                  child: Text(
                                    nextActionLabel(l10n, job.status)!,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.colorScheme.primary,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ],
                  );
                },
              ),
              const SizedBox(height: SSpacing.lg),
              Text(l10n.myJobsHistoryTitle, style: theme.textTheme.titleMedium),
              const SizedBox(height: SSpacing.sm),
              history.when(
                loading: () => const SSkeletonListTile(),
                error: (Object error, _) => SErrorState(
                  title: l10n.stateErrorGeneric,
                  message: localizedError(l10n, error),
                  retryLabel: l10n.actionRetry,
                  onRetry: () => ref.invalidate(providerJobsHistoryProvider),
                ),
                data: (List<JobRequest> jobs) => Column(
                  children: <Widget>[
                    for (final JobRequest job in jobs)
                      JobCard(
                        job: job,
                        categoryLabel: categoryLabelFor(job.categoryId),
                        onTap: () => unawaited(
                          context.push(
                            AppRoutes.providerJobExecutionPath(job.id),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
