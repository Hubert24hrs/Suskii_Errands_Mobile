import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:suskii_design/suskii_design.dart';
import 'package:suskii_domain/suskii_domain.dart';
import 'package:suskii_l10n/suskii_l10n.dart';

import '../../app/error_l10n.dart';
import '../../app/providers.dart';
import 'wallet_page.dart';

/// Referrals (M5): the user's code, campaign stats and referral-earnings
/// withdrawal. Reward amounts are set by the server-side campaign; the screen
/// only renders the returned summary.
class ReferralsPage extends ConsumerWidget {
  const ReferralsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final locale = Localizations.localeOf(context).languageCode;
    final summary = ref.watch(referralSummaryProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.referralTitle)),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(referralSummaryProvider);
          await ref.read(referralSummaryProvider.future);
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
                onRetry: () => ref.invalidate(referralSummaryProvider),
              ),
              data: (ReferralSummary data) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(SSpacing.lg),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            l10n.referralYourCode,
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: SSpacing.xs),
                          Row(
                            children: <Widget>[
                              Expanded(
                                child: Text(
                                  data.code,
                                  style: theme.textTheme.headlineSmall,
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.copy_outlined),
                                tooltip: l10n.referralCopy,
                                onPressed: () {
                                  unawaited(
                                    Clipboard.setData(
                                      ClipboardData(text: data.shareLink),
                                    ),
                                  );
                                  showSToast(context, l10n.referralCopied);
                                },
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: SSpacing.md),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(SSpacing.lg),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          _stat(
                            theme,
                            l10n.referralTotalEarned,
                            data.earnedTotal.format(locale: locale),
                          ),
                          _stat(
                            theme,
                            l10n.referralCompleted,
                            '${data.invitedCount}',
                          ),
                          _stat(
                            theme,
                            l10n.referralPending,
                            data.holding.format(locale: locale),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: SSpacing.md),
                  SButton(
                    label: l10n.referralWithdraw,
                    variant: SButtonVariant.secondary,
                    icon: Icons.payments_outlined,
                    onPressed: data.available.minorUnits > 0
                        ? () => showWithdrawSheet(
                            context,
                            currencyCode: data.available.currencyCode,
                            onSubmit: (Money amount, String key) => ref
                                .read(referralRepositoryProvider)
                                .requestWithdrawal(amount, idempotencyKey: key),
                          )
                        : null,
                  ),
                  const SizedBox(height: SSpacing.lg),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(SSpacing.lg),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            l10n.referralHowTitle,
                            style: theme.textTheme.titleMedium,
                          ),
                          const SizedBox(height: SSpacing.sm),
                          Text(
                            l10n.referralHowBody,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (data.invitedCount == 0) ...<Widget>[
                    const SizedBox(height: SSpacing.lg),
                    SEmptyState(
                      icon: Icons.group_add_outlined,
                      title: l10n.referralEmpty,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stat(ThemeData theme, String label, String value) {
    return Expanded(
      child: Column(
        children: <Widget>[
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: SSpacing.xs),
          Text(
            value,
            style: theme.textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
