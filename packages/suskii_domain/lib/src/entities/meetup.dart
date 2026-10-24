import 'package:freezed_annotation/freezed_annotation.dart';

import '../geo_point.dart';

part 'meetup.freezed.dart';
part 'meetup.g.dart';

/// Suskii Meet topics; wire values match `public.meetup_topic`.
enum MeetupTopic {
  @JsonValue('social')
  social,
  @JsonValue('sports_fitness')
  sportsFitness,
  @JsonValue('business_networking')
  businessNetworking,
  @JsonValue('learning')
  learning,
  @JsonValue('faith')
  faith,
  @JsonValue('arts_culture')
  artsCulture,
  @JsonValue('food_drink')
  foodDrink,
  @JsonValue('outdoors')
  outdoors,
  @JsonValue('other')
  other,
}

enum MeetupStatus {
  @JsonValue('published')
  published,
  @JsonValue('cancelled')
  cancelled,
}

/// A social meet-up as the server shows it to the caller. [hostFirstName] is
/// a first name only; [distanceKm] is null unless the list was asked for
/// near a point.
@freezed
abstract class Meetup with _$Meetup {
  const factory Meetup({
    required String id,
    required String title,
    required String description,
    required MeetupTopic topic,
    required String venueName,
    required GeoPoint venue,
    required DateTime startsAt,
    required DateTime endsAt,
    required int capacity,
    required int attendeeCount,
    required MeetupStatus status,
    required String hostFirstName,
    required bool isHost,
    required bool isAttending,
    double? distanceKm,
  }) = _Meetup;

  const Meetup._();

  factory Meetup.fromJson(Map<String, dynamic> json) => _$MeetupFromJson(json);

  int get spotsLeft => (capacity - attendeeCount).clamp(0, capacity);
  bool get isFull => attendeeCount >= capacity;
  bool get isCancelled => status == MeetupStatus.cancelled;

  /// Whether a person who is not the host may still join it at [now].
  bool canJoinAt(DateTime now) =>
      !isHost &&
      !isAttending &&
      !isCancelled &&
      !isFull &&
      startsAt.isAfter(now);
}

@freezed
abstract class MeetupAttendee with _$MeetupAttendee {
  const factory MeetupAttendee({
    required String firstName,
    required bool isHost,
    required DateTime joinedAt,
  }) = _MeetupAttendee;

  factory MeetupAttendee.fromJson(Map<String, dynamic> json) =>
      _$MeetupAttendeeFromJson(json);
}

/// What a host fills in. The server re-validates every field.
@freezed
abstract class MeetupDraft with _$MeetupDraft {
  const factory MeetupDraft({
    required String title,
    required String description,
    required MeetupTopic topic,
    required String venueName,
    required GeoPoint venue,
    required DateTime startsAt,
    required DateTime endsAt,
    required int capacity,
  }) = _MeetupDraft;

  factory MeetupDraft.fromJson(Map<String, dynamic> json) =>
      _$MeetupDraftFromJson(json);
}
