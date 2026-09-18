import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_design/suskii_design.dart';
import 'package:suskii_domain/suskii_domain.dart';
import 'package:suskii_l10n/suskii_l10n.dart';

import '../../app/error_l10n.dart';
import '../../app/labels.dart';
import '../../app/providers.dart';
import '../../app/router.dart';

/// Live offers board for one request: realtime offer stream, TTL countdowns
/// rendered against server time, accept/decline/counter with one idempotency
/// key per user intent.
class OffersBoard extends ConsumerStatefulWidget {
  const OffersBoard({required this.requestId, super.key});

  final String requestId;

  @override
  ConsumerState<OffersBoard> createState() => _OffersBoardState();
}

class _OffersBoardState extends ConsumerState<OffersBoard> {
  /// One key per intent, kept across retries of the same tap.
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

  Future<void> _accept(Offer offer) => _run('accept', offer.id, () async {
    await ref
        .read(offerRepositoryProvider)
        .acceptOffer(offer.id, idempotencyKey: _keyFor('accept', offer.id));
    if (mounted) {
      showSToast(context, AppLocalizations.of(context).offersAcceptedNote);
    }
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
    final offers = ref.watch(offersProvider(widget.requestId));
    final clock = ref.watch(serverClockProvider);
    return offers.when(
      loading: () => const Column(
        children: <Widget>[SSkeletonListTile(), SSkeletonListTile()],
      ),
      error: (Object error, _) => SErrorState(
        title: l10n.stateErrorGeneric,
        message: localizedError(l10n, error),
        retryLabel: l10n.actionRetry,
        onRetry: () => ref.invalidate(offersProvider(widget.requestId)),
      ),
      data: (List<Offer> data) {
        if (data.isEmpty) {
          return SEmptyState(
            icon: Icons.handshake_outlined,
            title: l10n.offersEmpty,
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (final Offer offer in data) ...<Widget>[
              SOfferCard(
                offer: offer,
                acceptLabel: l10n.offersAccept,
                counterLabel: l10n.offersCounter,
                declineLabel: l10n.offersDecline,
                etaLabel: offer.etaMinutes == null
                    ? ''
                    : l10n.offersEta(offer.etaMinutes!),
                clockOffset: clock.offset,
                onAccept: _actionable(offer) ? () => _accept(offer) : null,
                onCounter: _actionable(offer)
                    ? () => _openCounter(offer)
                    : null,
                onDecline: _actionable(offer) ? () => _decline(offer) : null,
              ),
              Padding(
                padding: const EdgeInsets.only(
                  left: SSpacing.md,
                  bottom: SSpacing.sm,
                ),
                child: Row(
                  children: <Widget>[
                    Chip(
                      label: Text(offerStatusLabel(l10n, offer.status)),
                      visualDensity: VisualDensity.compact,
                    ),
                    const SizedBox(width: SSpacing.sm),
                    Text(
                      l10n.offersRound(offer.round),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (offer.distanceMeters != null) ...<Widget>[
                      const SizedBox(width: SSpacing.sm),
                      Text(
                        l10n.offersDistance(
                          (offer.distanceMeters! / 1000).toStringAsFixed(1),
                        ),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                    const Spacer(),
                    if (_actionable(offer) &&
                        offer.expiresAt != null) ...<Widget>[
                      Text(
                        '${l10n.offersExpiresIn} ',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      SCountdownTimer(
                        // expiresAt is server time; the measured bootstrap
                        // offset corrects for a wrong device clock.
                        deadline: offer.expiresAt!,
                        clockOffset: clock.offset,
                      ),
                    ],
                  ],
                ),
              ),
            ],
            SButton(
              label: l10n.offersAskConcierge,
              variant: SButtonVariant.ghost,
              onPressed: () => context.push(AppRoutes.customerConcierge),
            ),
          ],
        );
      },
    );
  }

  bool _actionable(Offer offer) =>
      !_busy.contains(offer.id) &&
      (offer.status == OfferStatus.pending ||
          offer.status == OfferStatus.countered);
}
