// Provider tools over Supabase, as the mobile app reads them
// (packages/suskii_data/lib/src/supabase/supabase_provider_tools_repository.dart):
// the week of availability (`availability_schedules`, saved whole by
// `set_availability`), the earnings goal (`my_earnings_goal` /
// `set_earnings_goal`, progress computed server-side), insights
// (`my_provider_insights`) and the demand heatmap (`provider_demand_heatmap`:
// coarse cells, never pickups, none below the k-anonymity floor). Instant
// payout needs a payment gateway and says so.

import { AppError, ErrorCodes } from '@/mocks/errors';
import type {
  AvailabilitySlot,
  DemandZone,
  EarningsGoal,
  GoalPeriod,
  InstantPayoutQuote,
  Money,
  ProviderInsights,
  WalletTransaction,
} from '@/mocks/types';

import { SupabaseGateway, type Row } from './gateway';

function minutes(time: string): number {
  const [h, m, s] = time.split(':').map(Number);
  const total = h * 60 + m;
  // The last minute of the day is stored as 23:59:59: "until midnight".
  return s === 59 && total === 1439 ? 1440 : total;
}

export function availabilitySlotFromRow(row: Row): AvailabilitySlot {
  return {
    dayOfWeek: Number(row['weekday']),
    startMinutes: minutes(row['start_time'] as string),
    endMinutes: minutes(row['end_time'] as string),
  };
}

export function earningsGoalFromRow(row: Row): EarningsGoal {
  const currency = row['currency'] as string;
  return {
    target: { amountMinor: SupabaseGateway.asMinorUnits(row['target_minor']), currency },
    period: row['period'] === 'monthly' ? 'monthly' : 'weekly',
    progress: { amountMinor: SupabaseGateway.asMinorUnits(row['progress_minor']), currency },
  };
}

export function demandZoneFromRow(row: Row): DemandZone {
  const lat = Number(row['center_lat']);
  const lng = Number(row['center_lng']);
  const label = (row['label'] as string | null) ?? '';
  return {
    id: row['cell_id'] as string,
    // A cell outside any zone or city is labelled by its centre (about a kilometre).
    label: label === '' ? `${lat.toFixed(2)}, ${lng.toFixed(2)}` : label,
    center: { latitude: lat, longitude: lng },
    intensity: SupabaseGateway.asDecimal(row['intensity']),
    openRequests: Number(row['open_requests']),
  };
}

export function providerInsightsFromRow(row: Row): ProviderInsights {
  return {
    acceptanceRate: SupabaseGateway.asDecimal(row['acceptance_rate']),
    completionRate: SupabaseGateway.asDecimal(row['completion_rate']),
    avgRating: SupabaseGateway.asDecimal(row['avg_rating']),
    fiveStarShare: SupabaseGateway.asDecimal(row['five_star_share']),
    avgResponseTimeSeconds: Number(row['avg_response_time_seconds'] ?? 0),
    periodDays: Number(row['period_days'] ?? 30),
  };
}

export class SupabaseProviderToolsRepository {
  constructor(private readonly gateway: SupabaseGateway) {}

  async getAvailability(): Promise<AvailabilitySlot[]> {
    const me = await this.gateway.currentAuthUserId();
    if (!me) throw new AppError(ErrorCodes.unauthenticated);
    const rows = await this.gateway.selectList('availability_schedules', 'weekday, start_time, end_time', {
      column: 'provider_id',
      value: me,
      orderBy: 'weekday',
    });
    return rows.map(availabilitySlotFromRow);
  }

  async setAvailability(slots: AvailabilitySlot[], idempotencyKey: string): Promise<AvailabilitySlot[]> {
    await this.gateway.rpc('set_availability', {
      p_idempotency_key: idempotencyKey,
      p_slots: slots.map((slot) => ({
        weekday: slot.dayOfWeek,
        start_minutes: slot.startMinutes,
        end_minutes: slot.endMinutes,
      })),
    });
    return this.getAvailability();
  }

  async getEarningsGoal(): Promise<EarningsGoal | undefined> {
    const rows = (await this.gateway.rpc('my_earnings_goal')) as Row[];
    return rows.length === 0 ? undefined : earningsGoalFromRow(rows[0]);
  }

  async setEarningsGoal(target: Money, period: GoalPeriod, idempotencyKey: string): Promise<EarningsGoal> {
    await this.gateway.rpc('set_earnings_goal', {
      p_idempotency_key: idempotencyKey,
      p_target_minor: target.amountMinor,
      p_period: period,
    });
    const goal = await this.getEarningsGoal();
    if (!goal) throw new AppError(ErrorCodes.unknown);
    return goal;
  }

  async getDemandHeatmap(): Promise<DemandZone[]> {
    const rows = (await this.gateway.rpc('provider_demand_heatmap')) as Row[];
    return rows.map(demandZoneFromRow);
  }

  async getInsights(): Promise<ProviderInsights> {
    const rows = (await this.gateway.rpc('my_provider_insights')) as Row[];
    if (rows.length === 0) throw new AppError(ErrorCodes.unknown);
    return providerInsightsFromRow(rows[0]);
  }

  async quoteInstantPayout(_amount: Money): Promise<InstantPayoutQuote> {
    throw new AppError(ErrorCodes.featureUnavailable);
  }

  async requestInstantPayout(_amount: Money, _idempotencyKey: string): Promise<WalletTransaction> {
    throw new AppError(ErrorCodes.featureUnavailable);
  }
}
