import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_design/suskii_design.dart';
import 'package:suskii_domain/suskii_domain.dart';
import 'package:suskii_l10n/suskii_l10n.dart';

import '../../app/error_l10n.dart';
import '../../app/providers.dart';
import 'meet_labels.dart';

/// One meet-up: what, when, where, who is going (for the host and the people
/// going), and the one action that fits — join, leave or cancel.
class MeetDetailPage extends ConsumerStatefulWidget {
  const MeetDetailPage({required this.meetupId, super.key});

  final String meetupId;

  @override
  ConsumerState<MeetDetailPage> createState() => _MeetDetailPageState();
}

class _MeetDetailPageState extends ConsumerState<MeetDetailPage> {
  bool _busy = false;
  Object? _error;

  /// Held per intent so a retry after a dropped response is the same join or
  /// cancel on the server, not a second one.
  String? _joinKey;
  String? _cancelKey;

  void _refresh() {
    ref
      ..invalidate(meetupProvider(widget.meetupId))
      ..invalidate(meetupAttendeesProvider(widget.meetupId))
      ..invalidate(myMeetupsProvider)
      ..invalidate(nearbyMeetupsProvider);
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      _refresh();
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _join() => _run(() async {
    _joinKey ??= newIdempotencyKey();
    await ref
        .read(meetupRepositoryProvider)
        .joinMeetup(widget.meetupId, idempotencyKey: _joinKey!);
    _joinKey = null;
  });

  Future<void> _leave() => _run(
    () => ref.read(meetupRepositoryProvider).leaveMeetup(widget.meetupId),
  );

  Future<void> _cancel() async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        content: Text(l10n.meetCancelConfirm),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.actionNotNow),
          ),
          TextButton(
            key: const ValueKey<String>('meet.cancel.confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.meetCancel),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _run(() async {
      _cancelKey ??= newIdempotencyKey();
      await ref
          .read(meetupRepositoryProvider)
          .cancelMeetup(widget.meetupId, idempotencyKey: _cancelKey!);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final meetup = ref.watch(meetupProvider(widget.meetupId));
    return Scaffold(
      appBar: AppBar(title: Text(l10n.meetTitle)),
      body: meetup.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (Object error, _) => SErrorState(
          title: l10n.stateErrorGeneric,
          message: localizedError(l10n, error),
          retryLabel: l10n.actionRetry,
          onRetry: _refresh,
        ),
        data: (Meetup m) {
          final now = DateTime.now();
          final canSeeAttendees = m.isHost || m.isAttending;
          final error = _error;
          return ListView(
            padding: const EdgeInsets.all(SSpacing.gutter),
            children: <Widget>[
              Row(
                children: <Widget>[
                  SIconOrb(icon: meetupTopicIcon(m.topic), size: 52),
                  const SizedBox(width: SSpacing.md),
                  Expanded(
                    child: Text(
                      meetupTopicLabel(l10n, m.topic),
                      style: theme.textTheme.labelLarge,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: SSpacing.lg),
              Text(m.title, style: theme.textTheme.headlineSmall),
              const SizedBox(height: SSpacing.xs),
              Text(
                l10n.meetHostedBy(m.hostFirstName),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (m.isCancelled) ...<Widget>[
                const SizedBox(height: SSpacing.md),
                Text(
                  l10n.meetCancelled,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
              const SizedBox(height: SSpacing.lg),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.schedule_rounded),
                title: Text(meetupWhen(context, m.startsAt)),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.place_outlined),
                title: Text(m.venueName),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.groups_outlined),
                title: Text(l10n.meetGoing(m.attendeeCount)),
                subtitle: Text(
                  m.isFull ? l10n.meetFull : l10n.meetSpotsLeft(m.spotsLeft),
                ),
              ),
              if (m.description.isNotEmpty) ...<Widget>[
                const SizedBox(height: SSpacing.sm),
                Text(m.description, style: theme.textTheme.bodyLarge),
              ],
              const SizedBox(height: SSpacing.xl),
              if (error != null) ...<Widget>[
                Text(
                  localizedError(l10n, error),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
                const SizedBox(height: SSpacing.md),
              ],
              if (m.canJoinAt(now))
                SButton(
                  key: const ValueKey<String>('meet.join'),
                  label: l10n.meetJoin,
                  icon: Icons.how_to_reg_rounded,
                  loading: _busy,
                  onPressed: _busy ? null : _join,
                )
              else if (m.isAttending && !m.isCancelled)
                SButton(
                  key: const ValueKey<String>('meet.leave'),
                  label: l10n.meetLeave,
                  variant: SButtonVariant.secondary,
                  loading: _busy,
                  onPressed: _busy ? null : _leave,
                )
              else if (m.isHost && !m.isCancelled && m.endsAt.isAfter(now))
                SButton(
                  key: const ValueKey<String>('meet.cancel'),
                  label: l10n.meetCancel,
                  variant: SButtonVariant.danger,
                  loading: _busy,
                  onPressed: _busy ? null : _cancel,
                ),
              if (canSeeAttendees) ...<Widget>[
                const SizedBox(height: SSpacing.xl),
                SSectionHeader(title: l10n.meetAttendees),
                const SizedBox(height: SSpacing.sm),
                ref
                    .watch(meetupAttendeesProvider(m.id))
                    .when(
                      loading: () => const SSkeletonCard(height: 60),
                      error: (Object e, _) => Text(localizedError(l10n, e)),
                      data: (List<MeetupAttendee> people) => Wrap(
                        spacing: SSpacing.sm,
                        runSpacing: SSpacing.sm,
                        children: <Widget>[
                          for (final p in people)
                            Chip(
                              avatar: Icon(
                                p.isHost
                                    ? Icons.star_rounded
                                    : Icons.person_outline,
                                size: 18,
                              ),
                              label: Text(p.firstName),
                            ),
                        ],
                      ),
                    ),
              ],
              const SizedBox(height: SSpacing.xl),
              Text(
                l10n.meetSafetyBody,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
