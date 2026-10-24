import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_design/suskii_design.dart';
import 'package:suskii_domain/suskii_domain.dart';
import 'package:suskii_l10n/suskii_l10n.dart';

import '../../app/device_location.dart';
import '../../app/error_l10n.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import 'meet_labels.dart';

/// Host a meet-up in a public place. The server checks every field again;
/// what is checked here is only what saves a round trip.
class CreateMeetPage extends ConsumerStatefulWidget {
  const CreateMeetPage({super.key});

  @override
  ConsumerState<CreateMeetPage> createState() => _CreateMeetPageState();
}

class _CreateMeetPageState extends ConsumerState<CreateMeetPage> {
  final TextEditingController _title = TextEditingController();
  final TextEditingController _description = TextEditingController();
  final TextEditingController _venue = TextEditingController();
  final TextEditingController _capacity = TextEditingController(text: '10');

  MeetupTopic _topic = MeetupTopic.social;
  late DateTime _startsAt = _defaultStart();
  int _hours = 2;
  GeoPoint? _point;
  bool _locating = false;
  bool _busy = false;
  Object? _error;
  bool _needLocation = false;

  /// One key per draft: a retry after a lost response is the same meet-up.
  String? _createKey;

  static DateTime _defaultStart() {
    final t = DateTime.now().add(const Duration(days: 1));
    return DateTime(t.year, t.month, t.day, 10);
  }

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _venue.dispose();
    _capacity.dispose();
    super.dispose();
  }

  void _edited() => setState(() {
    _createKey = null;
    _error = null;
  });

  Future<void> _locate() async {
    setState(() => _locating = true);
    final reading = await ref.read(deviceLocationProvider).current();
    if (!mounted) return;
    setState(() {
      _locating = false;
      _point = reading.point;
      _needLocation = reading.point == null;
      if (reading.point == null) {
        _error = const AppError('ERR_LOCATION_UNAVAILABLE');
      }
      _createKey = null;
    });
  }

  Future<void> _pickStart() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: _startsAt,
      firstDate: now,
      lastDate: now.add(const Duration(days: 90)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_startsAt),
    );
    if (time == null) return;
    setState(() {
      _startsAt = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      );
      _createKey = null;
    });
  }

  Future<void> _publish() async {
    final point = _point;
    if (point == null) {
      setState(() => _needLocation = true);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _createKey ??= newIdempotencyKey();
      final id = await ref
          .read(meetupRepositoryProvider)
          .createMeetup(
            MeetupDraft(
              title: _title.text.trim(),
              description: _description.text.trim(),
              topic: _topic,
              venueName: _venue.text.trim(),
              venue: point,
              startsAt: _startsAt,
              endsAt: _startsAt.add(Duration(hours: _hours)),
              capacity: int.tryParse(_capacity.text.trim()) ?? 0,
            ),
            idempotencyKey: _createKey!,
          );
      ref
        ..invalidate(myMeetupsProvider)
        ..invalidate(nearbyMeetupsProvider);
      if (mounted) context.pushReplacement(AppRoutes.meetDetailPath(id));
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final error = _error;
    final ready =
        _title.text.trim().length >= 3 &&
        _venue.text.trim().length >= 2 &&
        !_busy;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.meetCreate)),
      body: ListView(
        padding: const EdgeInsets.all(SSpacing.gutter),
        children: <Widget>[
          STextField(
            key: const ValueKey<String>('meet.title'),
            label: l10n.meetFormTitle,
            controller: _title,
            onChanged: (_) => _edited(),
          ),
          const SizedBox(height: SSpacing.lg),
          STextField(
            key: const ValueKey<String>('meet.description'),
            label: l10n.meetFormDescription,
            controller: _description,
            maxLines: 4,
            onChanged: (_) => _edited(),
          ),
          const SizedBox(height: SSpacing.lg),
          Text(l10n.meetFormTopic, style: theme.textTheme.labelLarge),
          const SizedBox(height: SSpacing.xs),
          Wrap(
            spacing: SSpacing.sm,
            runSpacing: SSpacing.sm,
            children: <Widget>[
              for (final topic in MeetupTopic.values)
                ChoiceChip(
                  label: Text(meetupTopicLabel(l10n, topic)),
                  selected: _topic == topic,
                  onSelected: (_) => setState(() {
                    _topic = topic;
                    _createKey = null;
                  }),
                ),
            ],
          ),
          const SizedBox(height: SSpacing.lg),
          STextField(
            key: const ValueKey<String>('meet.venue'),
            label: l10n.meetFormVenue,
            hint: l10n.meetFormVenueHint,
            controller: _venue,
            onChanged: (_) => _edited(),
          ),
          const SizedBox(height: SSpacing.sm),
          OutlinedButton.icon(
            key: const ValueKey<String>('meet.locate'),
            onPressed: _locating ? null : _locate,
            icon: Icon(
              _point == null ? Icons.my_location_rounded : Icons.check_rounded,
            ),
            label: Text(
              _point == null
                  ? l10n.meetFormUseMyLocation
                  : l10n.meetFormLocationSet,
            ),
          ),
          if (_needLocation && _point == null)
            Padding(
              padding: const EdgeInsets.only(top: SSpacing.xs),
              child: Text(
                l10n.meetFormLocationNeeded,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          const SizedBox(height: SSpacing.lg),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.event_outlined),
            title: Text(l10n.meetFormStart),
            subtitle: Text(meetupWhen(context, _startsAt)),
            onTap: _pickStart,
          ),
          Text(l10n.meetFormDuration, style: theme.textTheme.labelLarge),
          const SizedBox(height: SSpacing.xs),
          Wrap(
            spacing: SSpacing.sm,
            children: <Widget>[
              for (final h in const <int>[1, 2, 3, 4, 6, 8])
                ChoiceChip(
                  label: Text(l10n.meetFormHours(h)),
                  selected: _hours == h,
                  onSelected: (_) => setState(() {
                    _hours = h;
                    _createKey = null;
                  }),
                ),
            ],
          ),
          const SizedBox(height: SSpacing.lg),
          STextField(
            key: const ValueKey<String>('meet.capacity'),
            label: l10n.meetFormCapacity,
            controller: _capacity,
            keyboardType: TextInputType.number,
            onChanged: (_) => _edited(),
          ),
          const SizedBox(height: SSpacing.xl),
          Text(
            l10n.meetSafetyBody,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (error != null) ...<Widget>[
            const SizedBox(height: SSpacing.md),
            Text(
              localizedError(l10n, error),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
          const SizedBox(height: SSpacing.lg),
          SButton(
            key: const ValueKey<String>('meet.publish'),
            label: l10n.meetFormPublish,
            loading: _busy,
            onPressed: ready ? _publish : null,
          ),
        ],
      ),
    );
  }
}
