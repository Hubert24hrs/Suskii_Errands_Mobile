import 'package:freezed_annotation/freezed_annotation.dart';

import '../money.dart';

part 'referral.freezed.dart';
part 'referral.g.dart';

@freezed
abstract class ReferralSummary with _$ReferralSummary {
  const factory ReferralSummary({
    required String code,
    required String shareLink,
    required int invitedCount,
    required int activeReferrals,
    required Money earnedTotal,
    required Money holding,
    required Money available,
  }) = _ReferralSummary;

  factory ReferralSummary.fromJson(Map<String, dynamic> json) =>
      _$ReferralSummaryFromJson(json);
}
