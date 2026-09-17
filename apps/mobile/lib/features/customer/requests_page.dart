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

final _requestHistoryProvider = FutureProvider<List<JobRequest>>(
  (ref) => ref.watch(requestRepositoryProvider).getMyRequestHistory(),
);

/// Active + past requests for the signed-in customer.
class CustomerRequestsPage extends ConsumerWidget {
  const CustomerRequestsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final active = ref.watch(activeJobsProvider);
    final history = ref.watch(_requestHistoryProvider);
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

    Widget section(AsyncValue<List<JobRequest>> value, VoidCallback onRetry) {
      return value.when(
        loading: () => const Column(
          children: <Widget>[SSkeletonListTile(), SSkeletonListTile()],
        ),
        error: (Object error, _) => SErrorState(
          title: l10n.stateErrorGeneric,
          message: localizedError(l10n, error),
          retryLabel: l10n.actionRetry,
          onRetry: onRetry,
        ),
        data: (List<JobRequest> jobs) => Column(
          children: <Widget>[
            for (final JobRequest job in jobs)
              JobCard(
                job: job,
                categoryLabel: categoryLabelFor(job.categoryId),
                onTap: () =>
                    context.push(AppRoutes.customerRequestDetailPath(job.id)),
              ),
          ],
        ),
      );
    }

    final bothEmpty =
        active.value?.isEmpty == true && history.value?.isEmpty == true;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.navRequests)),
      body: RefreshIndicator(
        onRefresh: () async {
          ref
            ..invalidate(activeJobsProvider)
            ..invalidate(_requestHistoryProvider);
          await ref.read(activeJobsProvider.future);
        },
        child: bothEmpty
            ? ListView(
                children: <Widget>[
                  const SizedBox(height: SSpacing.xxxl),
                  SEmptyState(
                    icon: Icons.inbox_outlined,
                    title: l10n.requestsEmptyTitle,
                    message: l10n.requestsEmptyBody,
                  ),
                ],
              )
            : ListView(
                padding: const EdgeInsets.all(SSpacing.lg),
                children: <Widget>[
                  Text(l10n.homeActiveJobs, style: theme.textTheme.titleMedium),
                  const SizedBox(height: SSpacing.sm),
                  section(active, () => ref.invalidate(activeJobsProvider)),
                  const SizedBox(height: SSpacing.xl),
                  Text(
                    l10n.requestsHistory,
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: SSpacing.sm),
                  section(
                    history,
                    () => ref.invalidate(_requestHistoryProvider),
                  ),
                ],
              ),
      ),
    );
  }
}
