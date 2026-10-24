import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_domain/suskii_domain.dart';

import 'supabase_gateway.dart';
import 'supabase_mappers.dart';

/// SafetyRepository over Supabase: `raise_sos` creates the incident
/// server-side (ops, security partner and trusted contacts are notified
/// there); the client renders the alert state from the RLS-scoped
/// `sos_incidents` stream.
class SupabaseSafetyRepository implements SafetyRepository {
  SupabaseSafetyRepository(this._gateway);

  final SupabaseGateway _gateway;

  static const String _columns =
      'id, request_id, raised_by, point, status, trusted_contacts_notified, '
      'created_at, resolved_at';

  @override
  Future<SosAlert> triggerSos({
    required String jobId,
    required String idempotencyKey,
    GeoPoint? location,
  }) async {
    final id = await _gateway.rpc('raise_sos', <String, Object?>{
      'p_idempotency_key': idempotencyKey,
      'p_request_id': jobId,
      'p_lat': location?.latitude,
      'p_lng': location?.longitude,
    });
    final row = await _gateway.selectSingle(
      'sos_incidents',
      _columns,
      column: 'id',
      value: SupabaseGateway.asId(id),
    );
    if (row == null) throw const AppError(ErrorCodes.unknown);
    return sosAlertFromRow(row);
  }

  @override
  Stream<SosAlert?> watchActiveSos(String jobId) => _gateway
      .streamRows(
        'sos_incidents',
        filterColumn: 'request_id',
        filterValue: jobId,
        topics: <String>['job:$jobId'],
      )
      .map((rows) {
        if (rows.isEmpty) return null;
        rows.sort(
          (a, b) =>
              (a['created_at'] as String).compareTo(b['created_at'] as String),
        );
        final latest = sosAlertFromRow(rows.last);
        return latest.status == SosStatus.active ? latest : null;
      });

  @override
  Future<TripShare> createTripShareLink(
    String jobId, {
    required String idempotencyKey,
  }) async {
    // `{share_id, token, url, expires_at}` (CR-20260923-01, contracts 2.0.0).
    // `url` is null when the server has no share base configured, and on a
    // replay, which never returns the token again: either way there is no
    // link to hand somebody, so say so rather than share a broken one.
    final result = await _gateway.rpc('create_trip_share', <String, Object?>{
      'p_idempotency_key': idempotencyKey,
      'p_request_id': jobId,
    });
    final share = Map<String, dynamic>.from(result as Map);
    final url = share['url'] as String?;
    if (url == null || url.isEmpty) {
      throw const AppError(ErrorCodes.featureUnavailable);
    }
    return TripShare(
      url: url,
      expiresAt: SupabaseGateway.asTimestamp(share['expires_at']),
    );
  }
}
