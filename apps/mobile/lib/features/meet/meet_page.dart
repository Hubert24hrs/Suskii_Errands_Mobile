import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:suskii_design/suskii_design.dart';
import 'package:suskii_domain/suskii_domain.dart';
import 'package:suskii_l10n/suskii_l10n.dart';

import '../../app/device_location.dart';
import '../../app/error_l10n.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import 'meet_labels.dart';

/// Where the list is sorted from. Asked once per visit, never stored: when
/// location is off or refused the list is simply sorted by time.
final _meetNearProvider = FutureProvider.autoDispose<GeoPoint?>(
  (ref) async => (await ref.watch(deviceLocationProvider).current()).point,
);

/// Suskii Meet: discover meet-ups near you, and the ones you host or joined.
class MeetPage extends ConsumerWidget {
  const MeetPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(l10n.meetTitle),
          bottom: TabBar(
            tabs: <Widget>[
              Tab(text: l10n.meetTabDiscover),
              Tab(text: l10n.meetTabMine),
            ],
          ),
        ),
        floatingActionButton: FloatingActionButton.extended(
          key: const ValueKey<String>('meet.create'),
          onPressed: () => context.push(AppRoutes.meetNew),
          icon: const Icon(Icons.add_rounded),
          label: Text(l10n.meetCreate),
        ),
        body: const TabBarView(children: <Widget>[_Discover(), _Mine()]),
      ),
    );
  }
}

class _Discover extends ConsumerWidget {
  const _Discover();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final near = ref.watch(_meetNearProvider);
    if (near.isLoading) return const _Loading();
    final list = ref.watch(nearbyMeetupsProvider(near.value));
    return _MeetupList(
      value: list,
      header: const _SafetyNote(),
      empty: SEmptyState(
        icon: Icons.groups_outlined,
        title: l10n.meetEmptyTitle,
        message: l10n.meetEmptyBody,
      ),
      onRefresh: () async {
        ref.invalidate(nearbyMeetupsProvider(near.value));
        await ref.read(nearbyMeetupsProvider(near.value).future);
      },
      onRetry: () => ref.invalidate(nearbyMeetupsProvider(near.value)),
    );
  }
}

class _Mine extends ConsumerWidget {
  const _Mine();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    return _MeetupList(
      value: ref.watch(myMeetupsProvider),
      empty: SEmptyState(
        icon: Icons.event_available_outlined,
        title: l10n.meetMineEmpty,
      ),
      onRefresh: () async {
        ref.invalidate(myMeetupsProvider);
        await ref.read(myMeetupsProvider.future);
      },
      onRetry: () => ref.invalidate(myMeetupsProvider),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(SSpacing.gutter),
    children: const <Widget>[SSkeletonCard(), SSkeletonCard()],
  );
}

class _MeetupList extends StatelessWidget {
  const _MeetupList({
    required this.value,
    required this.empty,
    required this.onRefresh,
    required this.onRetry,
    this.header,
  });

  final AsyncValue<List<Meetup>> value;
  final Widget empty;
  final Widget? header;
  final Future<void> Function() onRefresh;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return value.when(
      loading: () => const _Loading(),
      error: (Object error, _) => SErrorState(
        title: l10n.stateErrorGeneric,
        message: localizedError(l10n, error),
        retryLabel: l10n.actionRetry,
        onRetry: onRetry,
      ),
      data: (List<Meetup> meetups) => RefreshIndicator(
        onRefresh: onRefresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            SSpacing.gutter,
            SSpacing.lg,
            SSpacing.gutter,
            SSpacing.xxxl * 2,
          ),
          children: <Widget>[
            if (header != null) header!,
            if (meetups.isEmpty)
              empty
            else
              for (final (int i, Meetup m) in meetups.indexed)
                SFadeSlideIn(
                  index: i,
                  child: MeetupCard(meetup: m),
                ),
          ],
        ),
      ),
    );
  }
}

class _SafetyNote extends StatelessWidget {
  const _SafetyNote();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: SSpacing.lg),
      child: SGlass(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(Icons.shield_outlined, color: theme.colorScheme.primary),
            const SizedBox(width: SSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(l10n.meetSafetyTitle, style: theme.textTheme.titleSmall),
                  const SizedBox(height: SSpacing.xs),
                  Text(
                    l10n.meetSafetyBody,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
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

/// One meet-up in a list: topic, title, when, where, who and how many.
class MeetupCard extends StatelessWidget {
  const MeetupCard({required this.meetup, super.key});

  final Meetup meetup;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final m = meetup;
    final distance = m.distanceKm;
    final String badge;
    if (m.isCancelled) {
      badge = l10n.meetCancelled;
    } else if (m.isHost) {
      badge = l10n.meetYouHost;
    } else if (m.isAttending) {
      badge = l10n.meetYouGoing;
    } else if (m.isFull) {
      badge = l10n.meetFull;
    } else {
      badge = l10n.meetSpotsLeft(m.spotsLeft);
    }
    return Card(
      key: ValueKey<String>('meet.card.${m.id}'),
      margin: const EdgeInsets.only(bottom: SSpacing.md),
      child: InkWell(
        onTap: () => context.push(AppRoutes.meetDetailPath(m.id)),
        child: Padding(
          padding: const EdgeInsets.all(SSpacing.lg),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SIconOrb(icon: meetupTopicIcon(m.topic), size: 44),
              const SizedBox(width: SSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      m.title,
                      style: theme.textTheme.titleMedium,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: SSpacing.xs),
                    Text(
                      meetupWhen(context, m.startsAt),
                      style: theme.textTheme.bodyMedium,
                    ),
                    Text(
                      distance == null
                          ? m.venueName
                          : '${m.venueName} · '
                                '${l10n.meetDistanceKm(distance.toStringAsFixed(1))}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: SSpacing.sm),
                    Wrap(
                      spacing: SSpacing.sm,
                      runSpacing: SSpacing.xs,
                      children: <Widget>[
                        Chip(
                          label: Text(l10n.meetGoing(m.attendeeCount)),
                          visualDensity: VisualDensity.compact,
                        ),
                        Chip(
                          label: Text(badge),
                          visualDensity: VisualDensity.compact,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
