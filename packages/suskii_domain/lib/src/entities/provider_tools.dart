import 'package:freezed_annotation/freezed_annotation.dart';

import '../enums.dart';
import '../geo_point.dart';
import '../money.dart';

part 'provider_tools.freezed.dart';
part 'provider_tools.g.dart';

/// One weekly availability window (spec: added_features — provider tools).
/// Times are minutes since midnight, local time.
@freezed
abstract class AvailabilitySlot with _$AvailabilitySlot {
  const factory AvailabilitySlot({
    /// 1 = Monday … 7 = Sunday.
    required int dayOfWeek,
    required int startMinutes,
    required int endMinutes,
  }) = _AvailabilitySlot;

  factory AvailabilitySlot.fromJson(Map<String, dynamic> json) =>
      _$AvailabilitySlotFromJson(json);
}

/// Earnings goal (spec: added_features — earnings goals). [progress] is
/// server-computed; the client only sets [target] and [period].
@freezed
abstract class EarningsGoal with _$EarningsGoal {
  const factory EarningsGoal({
    required Money target,
    required GoalPeriod period,
    required Money progress,
  }) = _EarningsGoal;

  factory EarningsGoal.fromJson(Map<String, dynamic> json) =>
      _$EarningsGoalFromJson(json);
}

/// One demand-heatmap zone (spec: added_features — demand heatmap). Intensity
/// and open-request counts come from the server; the client renders them.
@freezed
abstract class DemandZone with _$DemandZone {
  const factory DemandZone({
    required String id,
    required String label,
    required GeoPoint center,
    required double intensity,
    required int openRequests,
  }) = _DemandZone;

  factory DemandZone.fromJson(Map<String, dynamic> json) =>
      _$DemandZoneFromJson(json);
}

/// Performance insights snapshot (spec: added_features — performance
/// insights). All values are server-computed over [periodDays].
@freezed
abstract class ProviderInsights with _$ProviderInsights {
  const factory ProviderInsights({
    required double acceptanceRate,
    required double completionRate,
    required double avgRating,
    required double fiveStarShare,
    required int avgResponseTimeSeconds,
    required int periodDays,
  }) = _ProviderInsights;

  factory ProviderInsights.fromJson(Map<String, dynamic> json) =>
      _$ProviderInsightsFromJson(json);
}

/// Server-computed instant-payout quote (spec: added_features — instant
/// payout is a paid feature). Fee/net are never computed on the client.
@freezed
abstract class InstantPayoutQuote with _$InstantPayoutQuote {
  const factory InstantPayoutQuote({
    required Money fee,
    required Money net,
    required int arrivesWithinMinutes,
  }) = _InstantPayoutQuote;

  factory InstantPayoutQuote.fromJson(Map<String, dynamic> json) =>
      _$InstantPayoutQuoteFromJson(json);
}
