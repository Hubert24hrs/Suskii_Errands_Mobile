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

/// Provider tools (M6): availability schedule, earnings goal, demand heatmap,
/// performance insights and instant payout. Stats, progress, zone intensity
/// and payout fees are all server-computed — the page only renders them.
class ProviderToolsPage extends ConsumerWidget {
  const ProviderToolsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.toolsTitle)),
      body: ListView(
        padding: const EdgeInsets.all(SSpacing.lg),
        children: const <Widget>[
          _AvailabilityCard(),
          SizedBox(height: SSpacing.lg),
          _EarningsGoalCard(),
          SizedBox(height: SSpacing.lg),
          _InstantPayoutCard(),
          SizedBox(height: SSpacing.lg),
          _HeatmapCard(),
          SizedBox(height: SSpacing.lg),
          _InsightsCard(),
        ],
      ),
    );
  }
}

/// Weekly availability editor: one row per weekday with an on/off switch and
/// from/to hour dropdowns. Saved in one idempotent setAvailability call.
class _AvailabilityCard extends ConsumerStatefulWidget {
  const _AvailabilityCard();

  @override
  ConsumerState<_AvailabilityCard> createState() => _AvailabilityCardState();
}

class _AvailabilityCardState extends ConsumerState<_AvailabilityCard> {
  /// Per-day selection: null = off, otherwise (startHour, endHour).
  final Map<int, (int, int)?> _days = <int, (int, int)?>{};
  bool _seeded = false;
  bool _busy = false;
  String? _saveKey;

  void _seedFrom(List<AvailabilitySlot> slots) {
    if (_seeded) return;
    _seeded = true;
    for (final slot in slots) {
      _days[slot.dayOfWeek] = (slot.startMinutes ~/ 60, slot.endMinutes ~/ 60);
    }
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      final slots = <AvailabilitySlot>[
        for (final entry in _days.entries)
          if (entry.value != null)
            AvailabilitySlot(
              dayOfWeek: entry.key,
              startMinutes: entry.value!.$1 * 60,
              endMinutes: entry.value!.$2 * 60,
            ),
      ];
      _saveKey ??= newIdempotencyKey();
      await ref
          .read(providerToolsRepositoryProvider)
          .setAvailability(slots, idempotencyKey: _saveKey!);
      _saveKey = null;
      ref.invalidate(availabilityProvider);
      if (mounted) {
        showSToast(
          context,
          AppLocalizations.of(context).toolsAvailabilitySaved,
        );
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
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final availability = ref.watch(availabilityProvider);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(SSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(l10n.toolsAvailability, style: theme.textTheme.titleMedium),
            const SizedBox(height: SSpacing.sm),
            availability.when(
              loading: () => const SSkeletonListTile(),
              error: (Object error, _) => SErrorState(
                title: l10n.stateErrorGeneric,
                message: localizedError(l10n, error),
                retryLabel: l10n.actionRetry,
                onRetry: () => ref.invalidate(availabilityProvider),
              ),
              data: (List<AvailabilitySlot> slots) {
                _seedFrom(slots);
                return Column(
                  children: <Widget>[
                    if (slots.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: SSpacing.sm),
                        child: Text(
                          l10n.toolsAvailabilityEmpty,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    for (var day = 1; day <= 7; day++) _dayRow(day, l10n),
                    const SizedBox(height: SSpacing.md),
                    SButton(
                      label: l10n.toolsAvailabilitySave,
                      loading: _busy,
                      onPressed: _busy ? null : _save,
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

  Widget _dayRow(int day, AppLocalizations l10n) {
    final value = _days[day];
    DropdownButton<int> hourDropdown(
      int hour,
      ValueChanged<int> onChanged, {
      required int max,
    }) {
      return DropdownButton<int>(
        value: hour,
        items: <DropdownMenuItem<int>>[
          for (var h = 0; h <= max; h++)
            DropdownMenuItem<int>(
              value: h,
              child: Text('${h.toString().padLeft(2, '0')}:00'),
            ),
        ],
        onChanged: (int? v) {
          if (v != null) onChanged(v);
        },
      );
    }

    return Row(
      children: <Widget>[
        SizedBox(width: 44, child: Text(weekdayLabel(l10n, day))),
        Switch(
          value: value != null,
          onChanged: (bool on) =>
              setState(() => _days[day] = on ? (8, 18) : null),
        ),
        if (value != null) ...<Widget>[
          hourDropdown(value.$1, (int v) {
            setState(() => _days[day] = (v, v < value.$2 ? value.$2 : v + 1));
          }, max: 23),
          const Text(' – '),
          hourDropdown(value.$2, (int v) {
            setState(() => _days[day] = (v > value.$1 ? value.$1 : v - 1, v));
          }, max: 24),
        ],
      ],
    );
  }
}

/// Earnings goal card: progress from the server, target editor sheet.
class _EarningsGoalCard extends ConsumerWidget {
  const _EarningsGoalCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final locale = Localizations.localeOf(context).languageCode;
    final goal = ref.watch(earningsGoalProvider);
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
                    l10n.toolsGoalTitle,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                TextButton(
                  onPressed: () => showGoalSheet(context),
                  child: Text(l10n.toolsGoalSet),
                ),
              ],
            ),
            goal.when(
              loading: () => const SSkeletonListTile(),
              error: (Object error, _) => SErrorState(
                title: l10n.stateErrorGeneric,
                message: localizedError(l10n, error),
                retryLabel: l10n.actionRetry,
                onRetry: () => ref.invalidate(earningsGoalProvider),
              ),
              data: (EarningsGoal? data) {
                if (data == null) {
                  return Text(
                    l10n.toolsGoalEmpty,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  );
                }
                final percent = data.target.minorUnits <= 0
                    ? 0
                    : ((data.progress.minorUnits / data.target.minorUnits) *
                              100)
                          .round();
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '${data.progress.format(locale: locale)} / '
                      '${data.target.format(locale: locale)} · '
                      '${goalPeriodLabel(l10n, data.period)}',
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: SSpacing.sm),
                    LinearProgressIndicator(
                      value: (percent / 100).clamp(0.0, 1.0),
                    ),
                    const SizedBox(height: SSpacing.xs),
                    Text(
                      l10n.toolsGoalProgress(percent),
                      style: theme.textTheme.bodySmall,
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

/// Set/edit the earnings goal (target in major units + period).
Future<void> showGoalSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (BuildContext context) => const _GoalSheet(),
  );
}

class _GoalSheet extends ConsumerStatefulWidget {
  const _GoalSheet();

  @override
  ConsumerState<_GoalSheet> createState() => _GoalSheetState();
}

class _GoalSheetState extends ConsumerState<_GoalSheet> {
  final TextEditingController _amount = TextEditingController();
  GoalPeriod _period = GoalPeriod.weekly;
  bool _busy = false;
  String? _goalKey;

  Future<void> _save() async {
    final major = double.tryParse(_amount.text.trim());
    if (major == null || major <= 0) return;
    setState(() => _busy = true);
    try {
      final currency =
          ref.read(walletSummaryProvider).value?.available.currencyCode ??
          'NGN';
      _goalKey ??= newIdempotencyKey();
      await ref
          .read(providerToolsRepositoryProvider)
          .setEarningsGoal(
            Money.fromMajorAmount(major, currency),
            _period,
            idempotencyKey: _goalKey!,
          );
      _goalKey = null;
      ref.invalidate(earningsGoalProvider);
      if (mounted) Navigator.of(context).pop();
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
            Text(l10n.toolsGoalSet, style: theme.textTheme.titleLarge),
            const SizedBox(height: SSpacing.md),
            STextField(
              label: l10n.toolsGoalAmount,
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
            ),
            const SizedBox(height: SSpacing.md),
            SegmentedButton<GoalPeriod>(
              segments: <ButtonSegment<GoalPeriod>>[
                ButtonSegment<GoalPeriod>(
                  value: GoalPeriod.weekly,
                  label: Text(l10n.toolsGoalWeekly),
                ),
                ButtonSegment<GoalPeriod>(
                  value: GoalPeriod.monthly,
                  label: Text(l10n.toolsGoalMonthly),
                ),
              ],
              selected: <GoalPeriod>{_period},
              onSelectionChanged: (Set<GoalPeriod> s) =>
                  setState(() => _period = s.first),
            ),
            const SizedBox(height: SSpacing.lg),
            SButton(
              label: l10n.toolsGoalSet,
              loading: _busy,
              onPressed: _busy ? null : _save,
            ),
          ],
        ),
      ),
    );
  }
}

/// Instant payout: amount → server quote (fee + net) → confirm.
class _InstantPayoutCard extends ConsumerStatefulWidget {
  const _InstantPayoutCard();

  @override
  ConsumerState<_InstantPayoutCard> createState() => _InstantPayoutCardState();
}

class _InstantPayoutCardState extends ConsumerState<_InstantPayoutCard> {
  final TextEditingController _amount = TextEditingController();
  InstantPayoutQuote? _quote;
  bool _quoting = false;
  bool _paying = false;
  String? _payoutKey;

  String get _currency =>
      ref.read(walletSummaryProvider).value?.available.currencyCode ?? 'NGN';

  Money? get _parsed {
    final major = double.tryParse(_amount.text.trim());
    if (major == null || major <= 0) return null;
    return Money.fromMajorAmount(major, _currency);
  }

  Future<void> _getQuote() async {
    final amount = _parsed;
    if (amount == null) return;
    setState(() {
      _quoting = true;
      _quote = null;
    });
    try {
      final quote = await ref
          .read(providerToolsRepositoryProvider)
          .quoteInstantPayout(amount);
      if (mounted) setState(() => _quote = quote);
    } on Object catch (error) {
      if (mounted) {
        showSToast(
          context,
          localizedError(AppLocalizations.of(context), error),
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _quoting = false);
    }
  }

  Future<void> _payout() async {
    final amount = _parsed;
    if (amount == null || _quote == null) return;
    setState(() => _paying = true);
    try {
      _payoutKey ??= newIdempotencyKey();
      await ref
          .read(providerToolsRepositoryProvider)
          .requestInstantPayout(amount, idempotencyKey: _payoutKey!);
      _payoutKey = null;
      ref
        ..invalidate(walletSummaryProvider)
        ..invalidate(walletTransactionsProvider);
      if (mounted) {
        final l10n = AppLocalizations.of(context);
        showSToast(
          context,
          l10n.toolsInstantPayoutDone(_quote!.arrivesWithinMinutes),
        );
        setState(() {
          _quote = null;
          _amount.clear();
        });
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
      if (mounted) setState(() => _paying = false);
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
    final locale = Localizations.localeOf(context).languageCode;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(SSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              l10n.toolsInstantPayoutTitle,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: SSpacing.xs),
            Text(
              l10n.toolsInstantPayoutBody,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: SSpacing.md),
            STextField(
              label: l10n.toolsInstantPayoutAmount,
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              onChanged: (_) => setState(() => _quote = null),
            ),
            const SizedBox(height: SSpacing.md),
            if (_quote != null)
              Padding(
                padding: const EdgeInsets.only(bottom: SSpacing.md),
                child: Text(
                  l10n.toolsInstantPayoutQuote(
                    _quote!.fee.format(locale: locale),
                    _quote!.net.format(locale: locale),
                  ),
                  style: theme.textTheme.titleSmall,
                ),
              ),
            if (_quote == null)
              SButton(
                label: l10n.toolsInstantPayoutQuoteCta,
                variant: SButtonVariant.secondary,
                loading: _quoting,
                onPressed: _quoting || _parsed == null ? null : _getQuote,
              )
            else
              SButton(
                label: l10n.toolsInstantPayoutCta,
                loading: _paying,
                onPressed: _paying ? null : _payout,
              ),
          ],
        ),
      ),
    );
  }
}

/// Demand heatmap: a simple grid colored by server-provided zone intensity
/// (no map SDK in the mock build, same approach as M4 tracking).
class _HeatmapCard extends ConsumerWidget {
  const _HeatmapCard();

  Color _colorFor(ThemeData theme, double intensity) {
    final base = theme.colorScheme.primary;
    return base.withValues(alpha: 0.15 + 0.75 * intensity.clamp(0.0, 1.0));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final zones = ref.watch(demandHeatmapProvider);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(SSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(l10n.toolsHeatmapTitle, style: theme.textTheme.titleMedium),
            const SizedBox(height: SSpacing.sm),
            zones.when(
              loading: () => const SSkeletonListTile(),
              error: (Object error, _) => SErrorState(
                title: l10n.stateErrorGeneric,
                message: localizedError(l10n, error),
                retryLabel: l10n.actionRetry,
                onRetry: () => ref.invalidate(demandHeatmapProvider),
              ),
              data: (List<DemandZone> data) {
                if (data.isEmpty) {
                  return Text(
                    l10n.toolsHeatmapEmpty,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  );
                }
                return Column(
                  children: <Widget>[
                    for (final zone in data)
                      Container(
                        margin: const EdgeInsets.only(bottom: SSpacing.sm),
                        padding: const EdgeInsets.all(SSpacing.md),
                        decoration: BoxDecoration(
                          color: _colorFor(theme, zone.intensity),
                          borderRadius: BorderRadius.circular(SRadius.md),
                        ),
                        child: Row(
                          children: <Widget>[
                            Expanded(
                              child: Text(
                                zone.label,
                                style: theme.textTheme.titleSmall,
                              ),
                            ),
                            Text(
                              l10n.toolsHeatmapRequests(zone.openRequests),
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
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

/// Performance insights tiles — all values server-computed.
class _InsightsCard extends ConsumerWidget {
  const _InsightsCard();

  Widget _tile(ThemeData theme, String label, String value) {
    return Expanded(
      child: Column(
        children: <Widget>[
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: SSpacing.xs),
          Text(value, style: theme.textTheme.titleMedium),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final insights = ref.watch(providerInsightsProvider);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(SSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(l10n.toolsInsightsTitle, style: theme.textTheme.titleMedium),
            const SizedBox(height: SSpacing.sm),
            insights.when(
              loading: () => const SSkeletonListTile(),
              error: (Object error, _) => SErrorState(
                title: l10n.stateErrorGeneric,
                message: localizedError(l10n, error),
                retryLabel: l10n.actionRetry,
                onRetry: () => ref.invalidate(providerInsightsProvider),
              ),
              data: (ProviderInsights data) => Column(
                children: <Widget>[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      _tile(
                        theme,
                        l10n.toolsInsightsAcceptance,
                        '${(data.acceptanceRate * 100).round()}%',
                      ),
                      _tile(
                        theme,
                        l10n.toolsInsightsCompletion,
                        '${(data.completionRate * 100).round()}%',
                      ),
                      _tile(
                        theme,
                        l10n.toolsInsightsRating,
                        data.avgRating.toStringAsFixed(1),
                      ),
                    ],
                  ),
                  const SizedBox(height: SSpacing.lg),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      _tile(
                        theme,
                        l10n.toolsInsightsFiveStar,
                        '${(data.fiveStarShare * 100).round()}%',
                      ),
                      _tile(
                        theme,
                        l10n.toolsInsightsResponse,
                        l10n.toolsInsightsSeconds(data.avgResponseTimeSeconds),
                      ),
                      Expanded(
                        child: Text(
                          l10n.toolsInsightsPeriod(data.periodDays),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ],
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
