import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:suskii_design/suskii_design.dart';
import 'package:suskii_domain/suskii_domain.dart';
import 'package:suskii_l10n/suskii_l10n.dart';

import '../../app/error_l10n.dart';
import '../../app/labels.dart';
import '../../app/providers.dart';

/// Wallet summary (server-computed balances) + transaction history.
class EarningsPage extends ConsumerWidget {
  const EarningsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final locale = Localizations.localeOf(context).languageCode;
    final summary = ref.watch(walletSummaryProvider);
    final transactions = ref.watch(walletTransactionsProvider);

    Widget balanceTile(String label, Money amount) {
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
              amount.format(locale: locale),
              style: theme.textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(l10n.navEarnings)),
      body: RefreshIndicator(
        onRefresh: () async {
          ref
            ..invalidate(walletSummaryProvider)
            ..invalidate(walletTransactionsProvider);
          await ref.read(walletSummaryProvider.future);
        },
        child: ListView(
          padding: const EdgeInsets.all(SSpacing.lg),
          children: <Widget>[
            summary.when(
              loading: () => const SSkeletonListTile(),
              error: (Object error, _) => SErrorState(
                title: l10n.stateErrorGeneric,
                message: localizedError(l10n, error),
                retryLabel: l10n.actionRetry,
                onRetry: () => ref.invalidate(walletSummaryProvider),
              ),
              data: (WalletSummary data) => Card(
                child: Padding(
                  padding: const EdgeInsets.all(SSpacing.lg),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      balanceTile(l10n.earningsAvailable, data.available),
                      balanceTile(l10n.earningsPending, data.pending),
                      if (data.lifetimeEarned != null)
                        balanceTile(
                          l10n.earningsLifetime,
                          data.lifetimeEarned!,
                        ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: SSpacing.xl),
            Text(l10n.earningsHistory, style: theme.textTheme.titleMedium),
            const SizedBox(height: SSpacing.sm),
            transactions.when(
              loading: () => const Column(
                children: <Widget>[SSkeletonListTile(), SSkeletonListTile()],
              ),
              error: (Object error, _) => SErrorState(
                title: l10n.stateErrorGeneric,
                message: localizedError(l10n, error),
                retryLabel: l10n.actionRetry,
                onRetry: () => ref.invalidate(walletTransactionsProvider),
              ),
              data: (List<WalletTransaction> data) {
                if (data.isEmpty) {
                  return SEmptyState(
                    icon: Icons.receipt_long_outlined,
                    title: l10n.earningsEmpty,
                  );
                }
                return Column(
                  children: <Widget>[
                    for (final WalletTransaction txn in data)
                      Card(
                        child: ListTile(
                          leading: Icon(
                            txn.amount.isNegative
                                ? Icons.arrow_upward
                                : Icons.arrow_downward,
                            color: txn.amount.isNegative
                                ? theme.colorScheme.error
                                : theme.colorScheme.primary,
                          ),
                          title: Text(
                            transactionLabel(l10n, txn.descriptionKey),
                          ),
                          subtitle: Text(
                            MaterialLocalizations.of(context)
                                .formatShortDate(txn.createdAt),
                          ),
                          trailing: Text(
                            txn.amount.format(locale: locale),
                            style: theme.textTheme.titleSmall,
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
    );
  }
}
