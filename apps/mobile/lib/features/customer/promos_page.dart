import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_design/suskii_design.dart';
import 'package:suskii_domain/suskii_domain.dart';
import 'package:suskii_l10n/suskii_l10n.dart';

import '../../app/error_l10n.dart';
import '../../app/providers.dart';

/// Promo campaigns (M5). Validity and discount math are server decisions —
/// redeeming an unknown/expired/used code fails with ERR_PROMO_INVALID.
class PromosPage extends ConsumerStatefulWidget {
  const PromosPage({super.key});

  @override
  ConsumerState<PromosPage> createState() => _PromosPageState();
}

class _PromosPageState extends ConsumerState<PromosPage> {
  final TextEditingController _code = TextEditingController();
  bool _busy = false;

  /// One key per redeem intent: kept on failure so a retried apply replays.
  String? _redeemKey;

  String _titleFor(AppLocalizations l10n, Promo promo) =>
      switch (promo.titleKey) {
        'promoWelcomeTitle' => l10n.promoWelcomeTitle,
        'promoFestiveTitle' => l10n.promoFestiveTitle,
        _ => promo.titleKey,
      };

  String _bodyFor(AppLocalizations l10n, Promo promo) =>
      switch (promo.descriptionKey) {
        'promoWelcomeBody' => l10n.promoWelcomeBody,
        'promoFestiveBody' => l10n.promoFestiveBody,
        _ => promo.descriptionKey,
      };

  Future<void> _redeem() async {
    final code = _code.text.trim();
    if (code.isEmpty) return;
    setState(() => _busy = true);
    try {
      _redeemKey ??= newIdempotencyKey();
      await ref
          .read(promoRepositoryProvider)
          .redeemPromo(code, idempotencyKey: _redeemKey!);
      _redeemKey = null;
      _code.clear();
      ref.invalidate(promosProvider);
      if (mounted) {
        showSToast(context, AppLocalizations.of(context).promoRedeemedToast);
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
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final locale = Localizations.localeOf(context).languageCode;
    final promos = ref.watch(promosProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.promosTitle)),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(promosProvider);
          await ref.read(promosProvider.future);
        },
        child: ListView(
          padding: const EdgeInsets.all(SSpacing.lg),
          children: <Widget>[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(SSpacing.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Text(
                      l10n.promoRedeemTitle,
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: SSpacing.md),
                    STextField(
                      label: l10n.promoCodeHint,
                      controller: _code,
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: SSpacing.md),
                    SButton(
                      label: l10n.promoRedeemCta,
                      loading: _busy,
                      onPressed: _busy || _code.text.trim().isEmpty
                          ? null
                          : _redeem,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: SSpacing.lg),
            promos.when(
              loading: () => const Column(
                children: <Widget>[SSkeletonListTile(), SSkeletonListTile()],
              ),
              error: (Object error, _) => SErrorState(
                title: l10n.stateErrorGeneric,
                message: localizedError(l10n, error),
                retryLabel: l10n.actionRetry,
                onRetry: () => ref.invalidate(promosProvider),
              ),
              data: (List<Promo> data) {
                if (data.isEmpty) {
                  return SEmptyState(
                    icon: Icons.local_offer_outlined,
                    title: l10n.promoEmpty,
                  );
                }
                return Column(
                  children: <Widget>[
                    for (final Promo promo in data)
                      _PromoCard(
                        promo: promo,
                        title: _titleFor(l10n, promo),
                        body: _bodyFor(l10n, promo),
                        expired: promo.expiresAt.isBefore(DateTime.now()),
                        locale: locale,
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

class _PromoCard extends StatelessWidget {
  const _PromoCard({
    required this.promo,
    required this.title,
    required this.body,
    required this.expired,
    required this.locale,
  });

  final Promo promo;
  final String title;
  final String body;
  final bool expired;
  final String locale;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(SSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(title, style: theme.textTheme.titleMedium),
                ),
                if (promo.redeemed)
                  Chip(label: Text(l10n.promoRedeemedBadge))
                else if (expired)
                  Chip(label: Text(l10n.promoExpiredBadge)),
              ],
            ),
            Text(
              l10n.promoPercentOff(promo.percentOff),
              style: theme.textTheme.titleLarge?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: SSpacing.xs),
            Text(body, style: theme.textTheme.bodyMedium),
            if (promo.maxDiscount != null) ...<Widget>[
              const SizedBox(height: SSpacing.xs),
              Text(
                l10n.promoMaxDiscount(
                  promo.maxDiscount!.format(locale: locale),
                ),
                style: theme.textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: SSpacing.xs),
            Text(
              l10n.promoExpiresAt(
                MaterialLocalizations.of(context)
                    .formatShortDate(promo.expiresAt),
              ),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
