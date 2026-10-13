import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_domain/suskii_domain.dart';

import 'supabase_gateway.dart';

/// Provider tools over Supabase: the week of availability
/// (`availability_schedules`, saved whole by `set_availability`), the
/// earnings goal (`set_earnings_goal` / `my_earnings_goal`, progress computed
/// server-side) and the insights card (`my_provider_insights`).
///
/// Two tools have no backend and say so rather than inventing numbers: the
/// demand heatmap (aggregating customers' pickup points needs its own privacy
/// design) and instant payout (a payment gateway, client action 4).
class SupabaseProviderToolsRepository implements ProviderToolsRepository {
  SupabaseProviderToolsRepository(this._gateway);

  final SupabaseGateway _gateway;

  @override
  Future<List<AvailabilitySlot>> getAvailability() async {
    final userId = _gateway.currentAuthUserId;
    if (userId == null) throw const AppError(ErrorCodes.unauthenticated);
    final rows = await _gateway.selectList(
      'availability_schedules',
      'weekday, start_time, end_time',
      column: 'provider_id',
      value: userId,
      orderBy: 'weekday',
    );
    return rows.map(availabilitySlotFromRow).toList(growable: false);
  }

  @override
  Future<List<AvailabilitySlot>> setAvailability(
    List<AvailabilitySlot> slots, {
    required String idempotencyKey,
  }) async {
    await _gateway.rpc('set_availability', <String, Object?>{
      'p_idempotency_key': idempotencyKey,
      'p_slots': slots.map(availabilitySlotToWire).toList(growable: false),
    });
    return getAvailability();
  }

  @override
  Future<EarningsGoal?> getEarningsGoal() async {
    final rows = List<Map<String, dynamic>>.from(
      await _gateway.rpc('my_earnings_goal') as List<dynamic>,
    );
    return rows.isEmpty ? null : earningsGoalFromRow(rows.first);
  }

  @override
  Future<EarningsGoal> setEarningsGoal(
    Money target,
    GoalPeriod period, {
    required String idempotencyKey,
  }) async {
    await _gateway.rpc('set_earnings_goal', <String, Object?>{
      'p_idempotency_key': idempotencyKey,
      'p_target_minor': target.minorUnits,
      'p_period': period.name,
    });
    final goal = await getEarningsGoal();
    if (goal == null) throw const AppError(ErrorCodes.unknown);
    return goal;
  }

  @override
  Future<List<DemandZone>> getDemandHeatmap() async =>
      throw const AppError(ErrorCodes.featureUnavailable);

  @override
  Future<ProviderInsights> getInsights() async {
    final rows = List<Map<String, dynamic>>.from(
      await _gateway.rpc('my_provider_insights') as List<dynamic>,
    );
    if (rows.isEmpty) throw const AppError(ErrorCodes.unknown);
    return providerInsightsFromRow(rows.first);
  }

  @override
  Future<InstantPayoutQuote> quoteInstantPayout(Money amount) async =>
      throw const AppError(ErrorCodes.featureUnavailable);

  @override
  Future<WalletTransaction> requestInstantPayout(
    Money amount, {
    required String idempotencyKey,
  }) async => throw const AppError(ErrorCodes.featureUnavailable);
}

int _minutes(String time) {
  final parts = time.split(':').map(int.parse).toList();
  final minutes = parts[0] * 60 + parts[1];
  // The last minute of the day is stored as 23:59:59: "until midnight".
  return parts.length > 2 && parts[2] == 59 && minutes == 1439 ? 1440 : minutes;
}

/// An `availability_schedules` row (ISO weekday; times of day).
AvailabilitySlot availabilitySlotFromRow(Map<String, dynamic> row) =>
    AvailabilitySlot(
      dayOfWeek: (row['weekday'] as num).toInt(),
      startMinutes: _minutes(row['start_time'] as String),
      endMinutes: _minutes(row['end_time'] as String),
    );

/// A slot as `set_availability` takes it.
Map<String, Object> availabilitySlotToWire(AvailabilitySlot slot) =>
    <String, Object>{
      'weekday': slot.dayOfWeek,
      'start_minutes': slot.startMinutes,
      'end_minutes': slot.endMinutes,
    };

/// A `my_earnings_goal` row.
EarningsGoal earningsGoalFromRow(Map<String, dynamic> row) {
  final currency = row['currency'] as String;
  return EarningsGoal(
    target: Money(SupabaseGateway.asMinorUnits(row['target_minor']), currency),
    period: GoalPeriod.values.byName(row['period'] as String),
    progress: Money(
      SupabaseGateway.asMinorUnits(row['progress_minor']),
      currency,
    ),
  );
}

/// A `my_provider_insights` row. Rates arrive as `numeric` (0–1).
ProviderInsights providerInsightsFromRow(Map<String, dynamic> row) =>
    ProviderInsights(
      acceptanceRate: SupabaseGateway.asDecimal(row['acceptance_rate']),
      completionRate: SupabaseGateway.asDecimal(row['completion_rate']),
      avgRating: SupabaseGateway.asDecimal(row['avg_rating']),
      fiveStarShare: SupabaseGateway.asDecimal(row['five_star_share']),
      avgResponseTimeSeconds:
          (row['avg_response_time_seconds'] as num?)?.toInt() ?? 0,
      periodDays: (row['period_days'] as num?)?.toInt() ?? 30,
    );
