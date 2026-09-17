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

/// Customer home: greeting, active jobs, quick category grid.
class CustomerHomePage extends ConsumerWidget {
  const CustomerHomePage({super.key});

  String _categoryLabelFor(
    AppLocalizations l10n,
    List<ServiceCategory> categories,
    String categoryId,
  ) {
    for (final ServiceCategory category in categories) {
      if (category.id == categoryId)
        return categoryLabel(l10n, category.labelKey);
    }
    return l10n.catCustom;
  }

  IconData _categoryIcon(String iconKey) => switch (iconKey) {
    'package' => Icons.local_shipping_outlined,
    'cart' => Icons.shopping_cart_outlined,
    'sparkles' => Icons.auto_awesome_outlined,
    'truck' => Icons.local_shipping_outlined,
    'wrench' => Icons.build_outlined,
    'person' => Icons.person_outline,
    'document' => Icons.description_outlined,
    'food' => Icons.restaurant_outlined,
    'car' => Icons.directions_car_outlined,
    'laptop' => Icons.laptop_outlined,
    'calendar' => Icons.event_outlined,
    _ => Icons.auto_fix_high_outlined,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final user =
        ref.watch(authStateProvider).value?.user ??
        ref.watch(bootstrapProvider).value?.user;
    final firstName = user?.displayName.split(' ').first ?? '';
    final jobs = ref.watch(activeJobsProvider);
    final categories = ref.watch(categoriesProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.navHome)),
      body: RefreshIndicator(
        onRefresh: () async {
          ref
            ..invalidate(activeJobsProvider)
            ..invalidate(categoriesProvider);
          await ref.read(activeJobsProvider.future);
        },
        child: ListView(
          padding: const EdgeInsets.all(SSpacing.lg),
          children: <Widget>[
            Text(
              l10n.homeGreeting(firstName),
              style: theme.textTheme.headlineSmall,
            ),
            if (user != null &&
                user.customerVerification !=
                    VerificationStatus.verified) ...<Widget>[
              const SizedBox(height: SSpacing.md),
              Card(
                child: ListTile(
                  leading: Icon(
                    Icons.badge_outlined,
                    color: theme.colorScheme.primary,
                  ),
                  title: Text(l10n.verifyRequiredBanner),
                  trailing: TextButton(
                    onPressed: () => context.push(AppRoutes.verifyCustomer),
                    child: Text(l10n.verifyRequiredAction),
                  ),
                ),
              ),
            ],
            const SizedBox(height: SSpacing.xl),
            Card(
              child: ListTile(
                leading: Icon(
                  Icons.auto_awesome,
                  color: theme.colorScheme.primary,
                ),
                title: Text(l10n.conciergeTitle),
                subtitle: Text(l10n.conciergeHint),
                onTap: () => context.push(AppRoutes.customerConcierge),
              ),
            ),
            const SizedBox(height: SSpacing.xl),
            Text(l10n.homeActiveJobs, style: theme.textTheme.titleMedium),
            const SizedBox(height: SSpacing.sm),
            jobs.when(
              loading: () => const Column(
                children: <Widget>[SSkeletonListTile(), SSkeletonListTile()],
              ),
              error: (Object error, _) => SErrorState(
                title: l10n.stateErrorGeneric,
                message: localizedError(l10n, error),
                retryLabel: l10n.actionRetry,
                onRetry: () => ref.invalidate(activeJobsProvider),
              ),
              data: (List<JobRequest> data) {
                if (data.isEmpty) {
                  return SEmptyState(
                    icon: Icons.inbox_outlined,
                    title: l10n.homeNoActiveJobs,
                  );
                }
                final cats = categories.value ?? const <ServiceCategory>[];
                return Column(
                  children: <Widget>[
                    for (final JobRequest job in data)
                      JobCard(
                        job: job,
                        categoryLabel: _categoryLabelFor(
                          l10n,
                          cats,
                          job.categoryId,
                        ),
                        onTap: () => context.push(
                          AppRoutes.customerRequestDetailPath(job.id),
                        ),
                      ),
                  ],
                );
              },
            ),
            const SizedBox(height: SSpacing.xl),
            Text(l10n.homeQuickCategories, style: theme.textTheme.titleMedium),
            const SizedBox(height: SSpacing.sm),
            categories.when(
              loading: () => const Column(
                children: <Widget>[SSkeletonListTile(), SSkeletonListTile()],
              ),
              error: (Object error, _) => SErrorState(
                title: l10n.stateErrorGeneric,
                message: localizedError(l10n, error),
                retryLabel: l10n.actionRetry,
                onRetry: () => ref.invalidate(categoriesProvider),
              ),
              data: (List<ServiceCategory> data) => GridView.count(
                crossAxisCount: 3,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: SSpacing.sm,
                crossAxisSpacing: SSpacing.sm,
                childAspectRatio: 0.95,
                children: <Widget>[
                  for (final ServiceCategory category in data)
                    Card(
                      child: InkWell(
                        onTap: () => context.push(
                          '${AppRoutes.customerRequestsNew}'
                          '?categoryId=${category.id}',
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(SSpacing.sm),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: <Widget>[
                              Icon(
                                _categoryIcon(category.iconKey),
                                color: theme.colorScheme.primary,
                              ),
                              const SizedBox(height: SSpacing.xs),
                              Text(
                                categoryLabel(l10n, category.labelKey),
                                style: theme.textTheme.labelSmall,
                                textAlign: TextAlign.center,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
