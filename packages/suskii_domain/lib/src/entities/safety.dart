import 'package:freezed_annotation/freezed_annotation.dart';

import '../enums.dart';
import '../geo_point.dart';

part 'safety.freezed.dart';
part 'safety.g.dart';

/// An SOS alert raised during an active job. Triggering is an action request:
/// the server notifies Suskii operations, the contracted city security
/// partner and the user's trusted contacts — the client only renders the
/// resulting alert state.
@freezed
abstract class SosAlert with _$SosAlert {
  const factory SosAlert({
    required String id,
    required String jobId,
    required String triggeredBy,
    required SosStatus status,
    required DateTime createdAt,
    GeoPoint? location,

    /// How many trusted contacts the server notified.
    @Default(0) int trustedContactsNotified,
  }) = _SosAlert;

  factory SosAlert.fromJson(Map<String, dynamic> json) =>
      _$SosAlertFromJson(json);
}

/// Shareable, expiring live-tracking link for trusted contacts
/// (spec: safety.live_trip_share).
class TripShare {
  const TripShare({required this.url, required this.expiresAt});

  final String url;

  /// Server timestamp — render countdowns against the server-clock offset.
  final DateTime expiresAt;
}
