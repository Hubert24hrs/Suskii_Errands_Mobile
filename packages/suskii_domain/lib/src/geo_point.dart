/// Latitude/longitude value object. Precision is capped at 7 decimals
/// (~1 cm) — enough for tracking, useless for pinpointing a home beyond it.
final class GeoPoint {
  const GeoPoint({required this.latitude, required this.longitude});

  final double latitude;
  final double longitude;

  factory GeoPoint.fromJson(Map<String, dynamic> json) => GeoPoint(
    latitude: (json['lat'] as num).toDouble(),
    longitude: (json['lng'] as num).toDouble(),
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'lat': latitude,
    'lng': longitude,
  };

  @override
  bool operator ==(Object other) =>
      other is GeoPoint &&
      other.latitude == latitude &&
      other.longitude == longitude;

  @override
  int get hashCode => Object.hash(latitude, longitude);

  @override
  String toString() => 'GeoPoint($latitude, $longitude)';
}

/// One position from the provider's device while on a job, as the job's
/// tracking channel and the heartbeat carry it (ADR-0009). [isMock] is the
/// platform's own mock-location flag; the server records it on the trail.
final class LiveFix {
  const LiveFix({
    required this.point,
    this.headingDegrees,
    this.speedMetresPerSecond,
    this.accuracyMetres,
    this.isMock = false,
  });

  final GeoPoint point;
  final double? headingDegrees;
  final double? speedMetresPerSecond;
  final double? accuracyMetres;
  final bool isMock;
}
