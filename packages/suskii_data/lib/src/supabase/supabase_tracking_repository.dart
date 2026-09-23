import 'package:suskii_domain/suskii_domain.dart';

import 'supabase_gateway.dart';
import 'supabase_mappers.dart';

/// TrackingRepository over Supabase: the provider's app samples its GPS into
/// `location_samples` (server-validated, anti-mock flagged); the customer
/// side renders the latest sample from the RLS-scoped stream.
class SupabaseTrackingRepository implements TrackingRepository {
  SupabaseTrackingRepository(this._gateway);

  final SupabaseGateway _gateway;

  @override
  Stream<GeoPoint> watchProviderLocation(String jobId) => _gateway
      .streamRows(
        'location_samples',
        primaryKey: <String>['id'],
        filterColumn: 'request_id',
        filterValue: jobId,
      )
      .map((rows) {
        if (rows.isEmpty) return null;
        rows.sort(
          (a, b) => (a['recorded_at'] as String).compareTo(
            b['recorded_at'] as String,
          ),
        );
        return geoPointFromWire(rows.last['pos']);
      })
      .where((point) => point != null)
      .cast<GeoPoint>();
}
