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

/// Customer wallet (M5): server-computed balances, transaction history and a
/// withdrawal request. Withdrawals are server-decided (KYC + name-matched
/// payout account enforced there).
class WalletPage extends ConsumerWidget {
  const WalletPage({super.key});

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
      appBar: AppBar(title: Text(l10n.walletTitle)),
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
              data: (WalletSummary data) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(SSpacing.lg),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          balanceTile(l10n.walletAvailable, data.available),
                          balanceTile(l10n.walletPending, data.pending),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: SSpacing.md),
                  SButton(
                    label: l10n.walletWithdraw,
                    variant: SButtonVariant.secondary,
                    icon: Icons.payments_outlined,
                    onPressed: data.available.minorUnits > 0
                        ? () => showWithdrawSheet(
                            context,
                            currencyCode: data.available.currencyCode,
                          )
                        : null,
                  ),
                ],
              ),
            ),
            const SizedBox(height: SSpacing.xl),
            Text(l10n.walletTransactions, style: theme.textTheme.titleMedium),
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
                    title: l10n.walletEmptyTransactions,
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

/// Withdrawal sheet shared by the wallet and referrals pages. The amount is
/// entered in major units and converted to integer minor units before the
/// (server-decided) request is sent.
Future<void> showWithdrawSheet(
  BuildContext context, {
  required String currencyCode,
  Future<WalletTransaction> Function(Money amount, String idempotencyKey)?
  onSubmit,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (BuildContext context) =>
        WithdrawSheet(currencyCode: currencyCode, onSubmit: onSubmit),
  );
}

class WithdrawSheet extends ConsumerStatefulWidget {
  const WithdrawSheet({required this.currencyCode, this.onSubmit, super.key});

  final String currencyCode;

  /// Defaults to the wallet withdrawal; the referrals page passes its own.
  final Future<WalletTransaction> Function(Money amount, String idempotencyKey)?
  onSubmit;

  @override
  ConsumerState<WithdrawSheet> createState() => _WithdrawSheetState();
}

class _WithdrawSheetState extends ConsumerState<WithdrawSheet> {
  final TextEditingController _amount = TextEditingController();
  bool _busy = false;

  /// One key per withdrawal intent (M3.14): kept on failure so a retried
  /// request replays instead of double-withdrawing.
  String? _withdrawKey;

  Money? get _parsed {
    final major = double.tryParse(_amount.text.trim());
    if (major == null || major <= 0) return null;
    return Money((major * 100).round(), widget.currencyCode);
  }

  Future<void> _submit() async {
    final amount = _parsed;
    if (amount == null) return;
    setState(() => _busy = true);
    try {
      _withdrawKey ??= newIdempotencyKey();
      final submit =
          widget.onSubmit ??
          (Money a, String key) => ref
              .read(walletRepositoryProvider)
              .requestWithdrawal(a, idempotencyKey: key);
      await submit(amount, _withdrawKey!);
      _withdrawKey = null;
      ref
        ..invalidate(walletSummaryProvider)
        ..invalidate(walletTransactionsProvider)
        ..invalidate(referralSummaryProvider);
      if (mounted) {
        final l10n = AppLocalizations.of(context);
        Navigator.of(context).pop();
        showSToast(context, l10n.walletWithdrawDone);
      }
    } on Object catch (error) {
      if (mounted) {
        showSToast(
          context,
          localizedError(AppLocalizations.of(context), error),
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: SSpacing.lg,
          right: SSpacing.lg,
          bottom: MediaQuery.of(context).viewInsets.bottom + SSpacing.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(l10n.walletWithdrawTitle, style: theme.textTheme.titleLarge),
            const SizedBox(height: SSpacing.md),
            STextField(
              label: '${l10n.walletWithdrawAmount} (${widget.currencyCode})',
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: SSpacing.lg),
            SButton(
              label: l10n.walletWithdrawCta,
              loading: _busy,
              onPressed: _busy || _parsed == null ? null : _submit,
            ),
          ],
        ),
      ),
    );
  }
}
