import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_design/suskii_design.dart';
import 'package:suskii_domain/suskii_domain.dart';
import 'package:suskii_l10n/suskii_l10n.dart';

import '../../app/error_l10n.dart';
import '../../app/labels.dart';
import '../../app/providers.dart';

/// The provider's own offers across all requests (M8.6): withdraw a pending
/// offer; accept, decline or counter back when the customer countered.
/// One idempotency key per (action, offer) intent, kept across retries.
class MyOffersPage extends ConsumerStatefulWidget {
  const MyOffersPage({super.key});

  @override
  ConsumerState<MyOffersPage> createState() => _MyOffersPageState();
}

class _MyOffersPageState extends ConsumerState<MyOffersPage> {
  final Map<String, String> _actionKeys = <String, String>{};
  final Set<String> _busy = <String>{};

  String _keyFor(String action, String offerId) =>
      _actionKeys.putIfAbsent('$action:$offerId', newIdempotencyKey);

  void _clearKey(String action, String offerId) =>
      _actionKeys.remove('$action:$offerId');

  Future<void> _run(
    String action,
    String offerId,
    Future<void> Function() f,
  ) async {
    if (_busy.contains(offerId)) return;
    setState(() => _busy.add(offerId));
    try {
      await f();
      _clearKey(action, offerId);
      ref.invalidate(myOffersProvider);
    } on Object catch (error) {
      if (mounted) {
        showSToast(
          context,
          localizedError(AppLocalizations.of(context), error),
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _busy.remove(offerId));
    }
  }

  Future<void> _withdraw(Offer offer) => _run('withdraw', offer.id, () async {
    await ref
        .read(offerRepositoryProvider)
        .withdrawOffer(offer.id, idempotencyKey: _keyFor('withdraw', offer.id));
  });

  /// Accepting the customer's counter agrees the job at the counter amount
  /// (server-side); the offer id identifies the negotiation thread.
  Future<void> _acceptCounter(Offer offer) =>
      _run('accept', offer.id, () async {
        await ref
            .read(offerRepositoryProvider)
            .acceptOffer(offer.id, idempotencyKey: _keyFor('accept', offer.id));
      });

  Future<void> _decline(Offer offer) => _run('decline', offer.id, () async {
    await ref
        .read(offerRepositoryProvider)
        .declineOffer(offer.id, idempotencyKey: _keyFor('decline', offer.id));
  });

  Future<void> _openCounter(Offer offer) async {
    final l10n = AppLocalizations.of(context);
    final currency = offer.amount.currencyCode;
    final amountController = TextEditingController();
    final messageController = TextEditingController();
    int? minor;
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (BuildContext sheetContext) => Padding(
        padding: EdgeInsets.fromLTRB(
          SSpacing.lg,
          0,
          SSpacing.lg,
          MediaQuery.of(sheetContext).viewInsets.bottom + SSpacing.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              l10n.offersCounterTitle,
              style: Theme.of(sheetContext).textTheme.titleMedium,
            ),
            const SizedBox(height: SSpacing.md),
            SMoneyField(
              label: l10n.offersCounterAmountLabel,
              currencyCode: currency,
              controller: amountController,
              onChangedMinorUnits: (int? v) => minor = v,
            ),
            const SizedBox(height: SSpacing.md),
            STextField(
              label: l10n.offersCounterMessageLabel,
              controller: messageController,
            ),
            const SizedBox(height: SSpacing.lg),
            SButton(
              label: l10n.offersCounterSend,
              onPressed: () => Navigator.of(sheetContext).pop(true),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || minor == null || !mounted) return;
    final amount = Money(minor!, currency);
    final message = messageController.text.trim();
    await _run('counter', offer.id, () async {
      await ref
          .read(offerRepositoryProvider)
          .counterOffer(
            offerId: offer.id,
            amount: amount,
            idempotencyKey: _keyFor('counter', offer.id),
            message: message.isEmpty ? null : message,
          );
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final offers = ref.watch(myOffersProvider);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.myOffersTitle)),
      body: SafeArea(
        child: offers.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(SSpacing.lg),
            child: Column(
              children: <Widget>[SSkeletonListTile(), SSkeletonListTile()],
            ),
          ),
          error: (Object error, _) => SErrorState(
            title: l10n.stateErrorGeneric,
            message: localizedError(l10n, error),
            retryLabel: l10n.actionRetry,
            onRetry: () => ref.invalidate(myOffersProvider),
          ),
          data: (List<Offer> data) {
            if (data.isEmpty) {
              return SEmptyState(
                icon: Icons.handshake_outlined,
                title: l10n.myOffersEmpty,
              );
            }
            return RefreshIndicator(
              onRefresh: () async {
                ref.invalidate(myOffersProvider);
                await ref.read(myOffersProvider.future);
              },
              child: ListView.builder(
                padding: const EdgeInsets.all(SSpacing.lg),
                itemCount: data.length,
                itemBuilder: (BuildContext context, int index) =>
                    _offerCard(l10n, data[index]),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _offerCard(AppLocalizations l10n, Offer offer) {
    final theme = Theme.of(context);
    final locale = Localizations.localeOf(context).languageCode;
    final clock = ref.watch(serverClockProvider);
    final busy = _busy.contains(offer.id);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(SSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    offer.amount.format(locale: locale),
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                Chip(
                  label: Text(offerStatusLabel(l10n, offer.status)),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: SSpacing.xs),
            Text(
              l10n.offersRound(offer.round),
              style: theme.textTheme.bodySmall,
            ),
            if (offer.message != null)
              Padding(
                padding: const EdgeInsets.only(top: SSpacing.xs),
                child: Text(offer.message!, style: theme.textTheme.bodySmall),
              ),
            if (offer.expiresAt != null &&
                (offer.status == OfferStatus.pending ||
                    offer.status == OfferStatus.countered))
              Padding(
                padding: const EdgeInsets.only(top: SSpacing.xs),
                child: Row(
                  children: <Widget>[
                    Text(
                      '${l10n.offersExpiresIn} ',
                      style: theme.textTheme.bodySmall,
                    ),
                    SCountdownTimer(
                      deadline: offer.expiresAt!,
                      clockOffset: clock.offset,
                    ),
                  ],
                ),
              ),
            if (offer.status == OfferStatus.pending) ...<Widget>[
              const SizedBox(height: SSpacing.sm),
              SButton(
                label: l10n.offerWithdraw,
                variant: SButtonVariant.secondary,
                loading: busy,
                onPressed: busy ? null : () => _withdraw(offer),
              ),
            ],
            if (offer.status == OfferStatus.countered) ...<Widget>[
              const SizedBox(height: SSpacing.sm),
              Row(
                children: <Widget>[
                  Expanded(
                    child: SButton(
                      label: l10n.offerAcceptCounter,
                      loading: busy,
                      onPressed: busy ? null : () => _acceptCounter(offer),
                    ),
                  ),
                  const SizedBox(width: SSpacing.sm),
                  Expanded(
                    child: SButton(
                      label: l10n.offersCounter,
                      variant: SButtonVariant.secondary,
                      onPressed: busy ? null : () => _openCounter(offer),
                    ),
                  ),
                  const SizedBox(width: SSpacing.sm),
                  Expanded(
                    child: SButton(
                      label: l10n.offersDecline,
                      variant: SButtonVariant.ghost,
                      onPressed: busy ? null : () => _decline(offer),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
