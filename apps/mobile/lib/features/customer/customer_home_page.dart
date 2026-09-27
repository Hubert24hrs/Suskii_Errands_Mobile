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
      body: SAuroraBackground(
        intensity: 0.55,
        child: SafeArea(
          bottom: false,
          child: RefreshIndicator(
            onRefresh: () async {
              ref
                ..invalidate(activeJobsProvider)
                ..invalidate(categoriesProvider);
              await ref.read(activeJobsProvider.future);
            },
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                SSpacing.gutter,
                SSpacing.lg,
                SSpacing.gutter,
                SSpacing.xxl,
              ),
              children: <Widget>[
                Row(
                  children: <Widget>[
                    const SBrandMark(size: 40, heroTag: null),
                    const SizedBox(width: SSpacing.md),
                    Expanded(
                      child: Text(
                        l10n.appName,
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: SSpacing.xl),
                Semantics(
                  header: true,
                  child: Text(
                    l10n.homeGreeting(firstName),
                    style: theme.textTheme.displaySmall,
                  ),
                ),
                if (user != null &&
                    user.customerVerification !=
                        VerificationStatus.verified) ...<Widget>[
                  const SizedBox(height: SSpacing.lg),
                  SGlass(
                    padding: const EdgeInsets.symmetric(
                      horizontal: SSpacing.lg,
                      vertical: SSpacing.sm,
                    ),
                    child: Row(
                      children: <Widget>[
                        Icon(
                          Icons.verified_user_outlined,
                          color: context.sColors.warning,
                        ),
                        const SizedBox(width: SSpacing.md),
                        Expanded(
                          child: Text(
                            l10n.verifyRequiredBanner,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                        TextButton(
                          onPressed: () =>
                              context.push(AppRoutes.verifyCustomer),
                          child: Text(l10n.verifyRequiredAction),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: SSpacing.xl),
                SPressable(
                  child: SGlass(
                    padding: EdgeInsets.zero,
                    child: InkWell(
                      onTap: () => context.push(AppRoutes.customerConcierge),
                      child: Padding(
                        padding: const EdgeInsets.all(SSpacing.xl),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            const SIconOrb(
                              icon: Icons.auto_awesome_rounded,
                              size: 52,
                            ),
                            const SizedBox(height: SSpacing.lg),
                            Text(
                              l10n.conciergeTitle,
                              style: theme.textTheme.headlineSmall,
                            ),
                            const SizedBox(height: SSpacing.xs),
                            Text(
                              l10n.conciergeHint,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: SSpacing.lg),
                            SButton(
                              label: l10n.homeAskConcierge,
                              icon: Icons.auto_awesome_rounded,
                              onPressed: () =>
                                  context.push(AppRoutes.customerConcierge),
                            ),
                            const SizedBox(height: SSpacing.sm),
                            SButton(
                              key: const ValueKey<String>('home.newRequest'),
                              label: l10n.createTitle,
                              icon: Icons.add_rounded,
                              variant: SButtonVariant.secondary,
                              onPressed: () =>
                                  context.push(AppRoutes.customerRequestsNew),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: SSpacing.xxl),
                SSectionHeader(title: l10n.homeQuickCategories),
                const SizedBox(height: SSpacing.md),
                categories.when(
                  loading: () => GridView.count(
                    crossAxisCount: 3,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    mainAxisSpacing: SSpacing.md,
                    crossAxisSpacing: SSpacing.md,
                    children: List<Widget>.generate(
                      6,
                      (_) => const SSkeletonCard(height: 96),
                    ),
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
                    mainAxisSpacing: SSpacing.md,
                    crossAxisSpacing: SSpacing.md,
                    childAspectRatio: 0.9,
                    children: <Widget>[
                      for (final (int i, ServiceCategory category)
                          in data.indexed)
                        SFadeSlideIn(
                          index: i,
                          child: _CategoryTile(
                            icon: _categoryIcon(category.iconKey),
                            label: categoryLabel(l10n, category.labelKey),
                            onTap: () => context.push(
                              '${AppRoutes.customerRequestsNew}'
                              '?categoryId=${category.id}',
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: SSpacing.xxl),
                SSectionHeader(title: l10n.homeActiveJobs),
                const SizedBox(height: SSpacing.sm),
                jobs.when(
                  loading: () => const Column(
                    children: <Widget>[SSkeletonCard(), SSkeletonCard()],
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
                        for (final (int i, JobRequest job) in data.indexed)
                          SFadeSlideIn(
                            index: i,
                            child: JobCard(
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
                          ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A quick-category tile: gradient icon orb over a raised surface.
class _CategoryTile extends StatelessWidget {
  const _CategoryTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SPressable(
      child: Card(
        margin: EdgeInsets.zero,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(SSpacing.sm),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                SIconOrb(icon: icon, size: 44),
                const SizedBox(height: SSpacing.sm),
                Text(
                  label,
                  style: theme.textTheme.labelMedium,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
