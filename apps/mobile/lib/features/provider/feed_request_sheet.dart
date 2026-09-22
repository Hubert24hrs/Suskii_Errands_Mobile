import 'dart:async';

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

/// Request-detail + offer-composer sheet opened from the provider feed
/// (M8.6). Shows the request summary and either the composer or, when the
/// provider already has a live offer on this request, that offer with a
/// withdraw action. One idempotency key per intent, kept across retries.
Future<void> showFeedRequestSheet(BuildContext context, JobRequest job) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (BuildContext sheetContext) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
      ),
      child: FeedRequestSheet(job: job),
    ),
  );
}

class FeedRequestSheet extends ConsumerStatefulWidget {
  const FeedRequestSheet({required this.job, super.key});

  final JobRequest job;

  @override
  ConsumerState<FeedRequestSheet> createState() => _FeedRequestSheetState();
}

class _FeedRequestSheetState extends ConsumerState<FeedRequestSheet> {
  final TextEditingController _amountController = TextEditingController();
  final TextEditingController _messageController = TextEditingController();
  int? _amountMinor;
  String? _offerKey;
  String? _withdrawKey;
  bool _busy = false;

  @override
  void dispose() {
    _amountController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } on Object catch (error) {
      if (mounted) {
        final l10n = AppLocalizations.of(context);
        showSToast(context, localizedError(l10n, error), isError: true);
        if (error is AppError && error.code == ErrorCodes.providerNotVerified) {
          Navigator.of(context).pop();
          unawaited(context.push(AppRoutes.providerOnboarding));
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit() {
    final minor = _amountMinor;
    if (minor == null || minor <= 0) return Future<void>.value();
    _offerKey ??= newIdempotencyKey();
    final key = _offerKey!;
    final message = _messageController.text.trim();
    return _run(() async {
      await ref
          .read(providerRepositoryProvider)
          .submitOffer(
            requestId: widget.job.id,
            amount: Money(minor, _currency()),
            idempotencyKey: key,
            message: message.isEmpty ? null : message,
          );
      ref.invalidate(myOffersProvider);
      _offerKey = null;
    });
  }

  Future<void> _withdraw(Offer offer) {
    _withdrawKey ??= newIdempotencyKey();
    final key = _withdrawKey!;
    return _run(() async {
      await ref
          .read(offerRepositoryProvider)
          .withdrawOffer(offer.id, idempotencyKey: key);
      ref.invalidate(myOffersProvider);
      _withdrawKey = null;
    });
  }

  String _currency() =>
      widget.job.preferredPrice?.currencyCode ??
      ref.read(bootstrapProvider).value?.countryPack.currencyCode ??
      'NGN';

  Offer? _ownLiveOffer(List<Offer> offers) {
    for (final offer in offers) {
      if (offer.requestId == widget.job.id &&
          (offer.status == OfferStatus.pending ||
              offer.status == OfferStatus.countered)) {
        return offer;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final locale = Localizations.localeOf(context).languageCode;
    final job = widget.job;

    final categories =
        ref.watch(categoriesProvider).value ?? const <ServiceCategory>[];
    var labelKey = 'catCustom';
    for (final category in categories) {
      if (category.id == job.categoryId) labelKey = category.labelKey;
    }

    final myOffers = ref.watch(myOffersProvider).value ?? const <Offer>[];
    final ownOffer = _ownLiveOffer(myOffers);

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          SSpacing.lg,
          0,
          SSpacing.lg,
          SSpacing.lg,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    categoryLabel(l10n, labelKey),
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                Text(
                  MaterialLocalizations.of(context)
                      .formatShortDate(job.createdAt),
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: SSpacing.sm),
            Text(job.description, style: theme.textTheme.bodyMedium),
            const SizedBox(height: SSpacing.md),
            _row(l10n.detailPickupLabel, job.pickup.label),
            if (job.pickup.landmarkNote != null)
              _row(l10n.createLandmarkLabel, job.pickup.landmarkNote!),
            if (job.destination != null)
              _row(l10n.detailDestinationLabel, job.destination!.label),
            if (job.preferredPrice != null)
              _row(
                l10n.detailPriceLabel,
                job.preferredPrice!.format(locale: locale),
              ),
            const SizedBox(height: SSpacing.lg),
            if (ownOffer != null)
              _ownOfferCard(l10n, theme, locale, ownOffer)
            else
              _composer(l10n, theme),
          ],
        ),
      ),
    );
  }

  Widget _composer(AppLocalizations l10n, ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(l10n.offerComposerTitle, style: theme.textTheme.titleMedium),
        const SizedBox(height: SSpacing.sm),
        SMoneyField(
          label: l10n.offerComposerAmountLabel,
          currencyCode: _currency(),
          controller: _amountController,
          onChangedMinorUnits: (int? value) {
            setState(() {
              _amountMinor = value;
              _offerKey = null;
            });
          },
        ),
        const SizedBox(height: SSpacing.sm),
        STextField(
          label: l10n.offersCounterMessageLabel,
          controller: _messageController,
          onChanged: (_) => _offerKey = null,
        ),
        const SizedBox(height: SSpacing.md),
        SButton(
          label: l10n.offerComposerSend,
          loading: _busy,
          onPressed: _busy || _amountMinor == null ? null : _submit,
        ),
      ],
    );
  }

  Widget _ownOfferCard(
    AppLocalizations l10n,
    ThemeData theme,
    String locale,
    Offer offer,
  ) {
    final clock = ref.watch(serverClockProvider);
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
              Text(offer.message!, style: theme.textTheme.bodySmall),
            if (offer.expiresAt != null) ...<Widget>[
              const SizedBox(height: SSpacing.xs),
              Row(
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
            ],
            const SizedBox(height: SSpacing.sm),
            SButton(
              label: l10n.offerWithdraw,
              variant: SButtonVariant.secondary,
              loading: _busy,
              onPressed: _busy ? null : () => _withdraw(offer),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: SSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 120,
            child: Text(label, style: theme.textTheme.bodySmall),
          ),
          Expanded(child: Text(value, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}
