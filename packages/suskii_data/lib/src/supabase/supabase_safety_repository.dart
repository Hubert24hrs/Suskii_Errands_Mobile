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
        primaryKey: <String>['id'],
        filterColumn: 'request_id',
        filterValue: jobId,
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
    // The RPC returns the raw share TOKEN only — the URL base and the
    // server-config TTL are server-side knowledge the contract does not hand
    // out yet (CR-20260923-01). Provisional: the token rides in `url` and the
    // expiry assumes the documented default TTL (60 min, remote_config
    // trip_share_ttl_minutes) until the CR lands.
    final token = await _gateway.rpc('create_trip_share', <String, Object?>{
      'p_idempotency_key': idempotencyKey,
      'p_request_id': jobId,
    });
    return TripShare(
      url: token as String,
      expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 60)),
    );
  }
}
