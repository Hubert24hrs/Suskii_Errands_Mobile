import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_domain/suskii_domain.dart';

import 'supabase_gateway.dart';
import 'supabase_mappers.dart';

/// RatingRepository over Supabase: `rate_job` writes the rating server-side
/// (window and one-per-party rules enforced there); reads are RLS-scoped
/// selects on `ratings` filtered to the caller as rater.
class SupabaseRatingRepository implements RatingRepository {
  SupabaseRatingRepository(this._gateway);

  final SupabaseGateway _gateway;

  static const String _columns =
      'id, request_id, rater_id, ratee_id, direction, stars, tags, comment, '
      'created_at';

  @override
  Future<Rating?> getMyRatingForJob(String jobId) async {
    final rows = await _gateway.selectList(
      'ratings',
      _columns,
      column: 'request_id',
      value: jobId,
    );
    final myId = _gateway.currentAuthUserId;
    for (final row in rows) {
      if (row['rater_id'] == myId) return ratingFromRow(row);
    }
    return null;
  }

  @override
  Future<Rating> submitRating({
    required String jobId,
    required int stars,
    required String idempotencyKey,
    List<String> tagKeys = const <String>[],
    String? comment,
  }) async {
    final id = await _gateway.rpc('rate_job', <String, Object?>{
      'p_idempotency_key': idempotencyKey,
      'p_request_id': jobId,
      'p_stars': stars,
      'p_tags': tagKeys.isEmpty ? null : tagKeys,
      'p_comment': comment,
    });
    final row = await _gateway.selectSingle(
      'ratings',
      _columns,
      column: 'id',
      value: SupabaseGateway.asId(id),
    );
    if (row == null) throw const AppError(ErrorCodes.unknown);
    return ratingFromRow(row);
  }
}
