import 'package:suskii_domain/suskii_domain.dart';

import 'supabase_gateway.dart';

/// TrackingRepository over Supabase, as ADR-0009 designs it: the provider's
/// position travels over the job's private Realtime Broadcast channel with no
/// database write per ping, and a movement-gated `heartbeat` keeps the
/// matching position and the trip trail (`location_samples`) current.
///
/// The customer does not read `location_samples` while the job runs — the RLS
/// matrix gives participants the trail only once the job is over — so the
/// live map is the broadcast alone. Earlier this read the table and showed
/// nothing for the whole job (audit 2026-09-27 Y.31).
class SupabaseTrackingRepository implements TrackingRepository {
  SupabaseTrackingRepository(this._gateway, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final SupabaseGateway _gateway;
  final DateTime Function() _clock;

  /// Client-originated event on `job:{id}` (contracts v1.3.0,
  /// realtime-events/client-events.json).
  static const String providerLocationEvent = 'provider.location';

  /// The heartbeat is a database write and the server drops one that has not
  /// moved; there is no point asking more often than the server's own
  /// maximum interval (`location_max_interval_s`, default 60) halves.
  static const Duration heartbeatInterval = Duration(seconds: 30);

  DateTime? _lastHeartbeat;

  static String topicFor(String jobId) => 'job:$jobId';

  @override
  Stream<GeoPoint> watchProviderLocation(String jobId) => _gateway
      .broadcasts(topicFor(jobId), providerLocationEvent)
      .map(_pointFrom)
      .where((point) => point != null)
      .cast<GeoPoint>();

  @override
  Future<void> publishProviderLocation(String jobId, LiveFix fix) async {
    Object? broadcastError;
    try {
      await _gateway.broadcast(
        topicFor(jobId),
        providerLocationEvent,
        <String, dynamic>{
          'lat': fix.point.latitude,
          'lng': fix.point.longitude,
          'heading': ?fix.headingDegrees,
          'accuracy_m': ?fix.accuracyMetres,
          'is_mock': fix.isMock,
          'at': _clock().toUtc().toIso8601String(),
        },
      );
    } on Object catch (error) {
      // A lost ping is replaced by the next one; the heartbeat still runs.
      broadcastError = error;
    }

    final now = _clock();
    final last = _lastHeartbeat;
    if (last == null || now.difference(last) >= heartbeatInterval) {
      _lastHeartbeat = now;
      await _gateway.rpc('heartbeat', <String, Object?>{
        'p_lat': fix.point.latitude,
        'p_lng': fix.point.longitude,
        'p_heading': fix.headingDegrees == null
            ? null
            : fix.headingDegrees!.round() % 360,
        'p_speed_cm_s': fix.speedMetresPerSecond == null
            ? null
            : (fix.speedMetresPerSecond! * 100).round(),
        'p_accuracy_m': fix.accuracyMetres?.round(),
        'p_is_mock': fix.isMock,
      });
    }
    if (broadcastError != null) throw broadcastError;
  }

  static GeoPoint? _pointFrom(Map<String, dynamic> payload) {
    final lat = payload['lat'];
    final lng = payload['lng'];
    if (lat is! num || lng is! num) return null;
    if (lat < -90 || lat > 90 || lng < -180 || lng > 180) return null;
    return GeoPoint(latitude: lat.toDouble(), longitude: lng.toDouble());
  }
}
