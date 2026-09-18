import 'package:freezed_annotation/freezed_annotation.dart';

part 'rating.freezed.dart';
part 'rating.g.dart';

/// Two-way rating after a job completes. One rating per party per job;
/// aggregate scores are server-computed with Bayesian averaging (the client
/// never calculates ratings).
@freezed
abstract class Rating with _$Rating {
  const factory Rating({
    required String id,
    required String jobId,
    required String raterId,
    required String rateeId,

    /// 1–5.
    required int stars,

    /// Localization keys of the selected quick tags (e.g. `ratingTagPunctual`).
    required List<String> tagKeys,
    String? comment,
    required DateTime createdAt,
  }) = _Rating;

  factory Rating.fromJson(Map<String, dynamic> json) => _$RatingFromJson(json);
}
