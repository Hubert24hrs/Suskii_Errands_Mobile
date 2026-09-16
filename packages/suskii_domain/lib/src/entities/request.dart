import 'package:freezed_annotation/freezed_annotation.dart';

import '../enums.dart';
import '../geo_point.dart';
import '../money.dart';
import 'offer.dart';

part 'request.freezed.dart';
part 'request.g.dart';

/// A pickup/destination: free-text label (landmark-based addressing is the
/// norm in our markets) plus optional coordinates.
@freezed
abstract class PlaceRef with _$PlaceRef {
  const factory PlaceRef({
    required String label,
    GeoPoint? point,
    String? landmarkNote,
  }) = _PlaceRef;

  factory PlaceRef.fromJson(Map<String, dynamic> json) =>
      _$PlaceRefFromJson(json);
}

@freezed
abstract class JobRequest with _$JobRequest {
  const factory JobRequest({
    required String id,
    required String customerId,
    required String categoryId,
    required bool isCustomCategory,
    required String description,
    required List<String> mediaPaths,
    required PlaceRef pickup,
    required Urgency urgency,
    required JobStatus status,
    required DateTime createdAt,
    PlaceRef? destination,
    DateTime? scheduledAt,
    Money? preferredPrice,
    Money? itemFloat,
    Money? declaredValue,
    Money? agreedPrice,

    /// Server-computed money breakdown for the agreed price. Null until AGREED.
    PriceBreakdown? agreedBreakdown,
    String? providerId,
    DateTime? expiresAt,
  }) = _JobRequest;

  factory JobRequest.fromJson(Map<String, dynamic> json) =>
      _$JobRequestFromJson(json);
}
