import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_domain/suskii_domain.dart';

import 'supabase_gateway.dart';

/// Suskii Meet over Supabase. Every read and write is a function
/// (`list_meetups`, `get_meetup`, `my_meetups`, `create_meetup`,
/// `join_meetup`, `leave_meetup`, `cancel_meetup`, `meetup_attendees`); the
/// tables have no client grant, so visibility rules live in one place.
class SupabaseMeetupRepository implements MeetupRepository {
  SupabaseMeetupRepository(this._gateway);

  final SupabaseGateway _gateway;

  Future<List<Meetup>> _rows(String fn, [Map<String, Object?>? args]) async {
    final rows = List<Map<String, dynamic>>.from(
      await _gateway.rpc(fn, args ?? const <String, Object?>{})
          as List<dynamic>,
    );
    return rows.map(meetupFromRow).toList(growable: false);
  }

  @override
  Future<List<Meetup>> listMeetups({
    GeoPoint? near,
    int radiusKm = 50,
    MeetupTopic? topic,
  }) => _rows('list_meetups', <String, Object?>{
    'p_lat': near?.latitude,
    'p_lng': near?.longitude,
    'p_radius_km': radiusKm,
    'p_topic': topic == null ? null : meetupTopicToWire(topic),
  });

  @override
  Future<List<Meetup>> myMeetups() => _rows('my_meetups');

  @override
  Future<Meetup> getMeetup(String meetupId) async {
    final rows = await _rows('get_meetup', <String, Object?>{
      'p_meetup_id': meetupId,
    });
    if (rows.isEmpty) throw const AppError(ErrorCodes.meetupNotFound);
    return rows.first;
  }

  @override
  Future<String> createMeetup(
    MeetupDraft draft, {
    required String idempotencyKey,
  }) async {
    final id = await _gateway.rpc('create_meetup', <String, Object?>{
      'p_idempotency_key': idempotencyKey,
      'p_title': draft.title,
      'p_description': draft.description,
      'p_topic': meetupTopicToWire(draft.topic),
      'p_venue_name': draft.venueName,
      'p_venue_lat': draft.venue.latitude,
      'p_venue_lng': draft.venue.longitude,
      'p_starts_at': draft.startsAt.toUtc().toIso8601String(),
      'p_ends_at': draft.endsAt.toUtc().toIso8601String(),
      'p_capacity': draft.capacity,
    });
    return id as String;
  }

  @override
  Future<int> joinMeetup(
    String meetupId, {
    required String idempotencyKey,
  }) async => (await _gateway.rpc('join_meetup', <String, Object?>{
    'p_idempotency_key': idempotencyKey,
    'p_meetup_id': meetupId,
  }) as num).toInt();

  @override
  Future<bool> leaveMeetup(String meetupId) async =>
      await _gateway.rpc('leave_meetup', <String, Object?>{
        'p_meetup_id': meetupId,
      }) ==
      true;

  @override
  Future<void> cancelMeetup(
    String meetupId, {
    required String idempotencyKey,
  }) async {
    await _gateway.rpc('cancel_meetup', <String, Object?>{
      'p_idempotency_key': idempotencyKey,
      'p_meetup_id': meetupId,
    });
  }

  @override
  Future<List<MeetupAttendee>> attendees(String meetupId) async {
    final rows = List<Map<String, dynamic>>.from(
      await _gateway.rpc('meetup_attendees', <String, Object?>{
        'p_meetup_id': meetupId,
      }) as List<dynamic>,
    );
    return rows
        .map(
          (Map<String, dynamic> r) => MeetupAttendee(
            firstName: r['first_name'] as String? ?? '',
            isHost: r['is_host'] as bool? ?? false,
            joinedAt: DateTime.parse(r['joined_at'] as String),
          ),
        )
        .toList(growable: false);
  }
}

const Map<MeetupTopic, String> _topicWire = <MeetupTopic, String>{
  MeetupTopic.social: 'social',
  MeetupTopic.sportsFitness: 'sports_fitness',
  MeetupTopic.businessNetworking: 'business_networking',
  MeetupTopic.learning: 'learning',
  MeetupTopic.faith: 'faith',
  MeetupTopic.artsCulture: 'arts_culture',
  MeetupTopic.foodDrink: 'food_drink',
  MeetupTopic.outdoors: 'outdoors',
  MeetupTopic.other: 'other',
};

String meetupTopicToWire(MeetupTopic topic) => _topicWire[topic]!;

MeetupTopic meetupTopicFromWire(String? wire) => _topicWire.entries
    .firstWhere(
      (MapEntry<MeetupTopic, String> e) => e.value == wire,
      orElse: () =>
          const MapEntry<MeetupTopic, String>(MeetupTopic.other, 'other'),
    )
    .key;

/// One row of `list_meetups` / `get_meetup` / `my_meetups`.
Meetup meetupFromRow(Map<String, dynamic> row) => Meetup(
  id: row['id'] as String,
  title: row['title'] as String,
  description: row['description'] as String? ?? '',
  topic: meetupTopicFromWire(row['topic'] as String?),
  venueName: row['venue_name'] as String,
  venue: GeoPoint(
    latitude: (row['venue_lat'] as num).toDouble(),
    longitude: (row['venue_lng'] as num).toDouble(),
  ),
  startsAt: DateTime.parse(row['starts_at'] as String),
  endsAt: DateTime.parse(row['ends_at'] as String),
  capacity: (row['capacity'] as num).toInt(),
  attendeeCount: (row['attendee_count'] as num? ?? 0).toInt(),
  status: row['status'] == 'cancelled'
      ? MeetupStatus.cancelled
      : MeetupStatus.published,
  hostFirstName: row['host_first_name'] as String? ?? '',
  isHost: row['is_host'] as bool? ?? false,
  isAttending: row['is_attending'] as bool? ?? false,
  distanceKm: (row['distance_km'] as num?)?.toDouble(),
);
