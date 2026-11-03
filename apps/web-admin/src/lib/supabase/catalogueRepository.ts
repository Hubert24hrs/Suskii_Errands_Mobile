// The service catalogue and Ask Suskii usage against the real backend (20261103120100, -120200).
// Every change asks for a second factor from the last five minutes first, so the console opens
// its re-authentication step before the server refuses; the server checks it again regardless.

import type {
  AiBudget,
  AiUsageSummary,
  AiUserUsage,
  CatalogueService,
  ServiceInput,
} from '@/mocks/types';
import { SupabaseAdminRepo } from './base';
import { SupabaseGateway, type Row } from './gateway';

const int = (value: unknown): number => (typeof value === 'number' ? Math.trunc(value) : Number(value ?? 0) || 0);
const texts = (value: unknown): Record<string, string> => {
  const out: Record<string, string> = {};
  if (value && typeof value === 'object' && !Array.isArray(value)) {
    for (const [lang, text] of Object.entries(value as Row)) if (typeof text === 'string') out[lang] = text;
  }
  return out;
};
const when = (value: unknown): Date | undefined =>
  value == null ? undefined : SupabaseGateway.asTimestamp(value);

export class SupabaseServicesRepository extends SupabaseAdminRepo {
  async listServices(): Promise<CatalogueService[]> {
    const rows = await this.gw.rpcRows('admin_service_catalogue');
    return rows.map((r) => ({
      id: SupabaseGateway.asId(r['id']),
      key: r['key'] as string,
      active: r['active'] === true,
      displayNames: texts(r['display_names']),
      descriptions: texts(r['descriptions']),
      iconKey: (r['icon_key'] as string | null) ?? 'magic',
      requiresVehicle: r['requires_vehicle'] === true,
      allowsCustom: r['allows_custom'] === true,
      sortOrder: int(r['sort_order']),
      requestCount: int(r['request_count']),
      openRequestCount: int(r['open_request_count']),
      providerCount: int(r['provider_count']),
      updatedAt: SupabaseGateway.asTimestamp(r['updated_at']),
    }));
  }

  async saveService(input: ServiceInput, idempotencyKey: string): Promise<void> {
    await this.requireRecentMfa('services.manage');
    await this.gw.rpc('admin_save_service', {
      p_idempotency_key: idempotencyKey,
      p_key: input.key,
      p_display_names: input.displayNames,
      p_descriptions: input.descriptions,
      p_icon_key: input.iconKey,
      p_requires_vehicle: input.requiresVehicle,
    });
  }

  async setServiceActive(key: string, active: boolean, reason: string): Promise<void> {
    await this.requireRecentMfa('services.manage');
    await this.gw.rpc('admin_set_service_active', { p_key: key, p_active: active, p_reason: reason });
  }
}

function budgetFrom(b: Row): AiBudget {
  return {
    dailyMicros: int(b['daily_micros']),
    monthlyMicros: int(b['monthly_micros']),
    spentTodayMicros: int(b['spent_today_micros']),
    spentThisMonthMicros: int(b['spent_this_month_micros']),
    dayExceeded: b['day_exceeded'] === true,
    monthExceeded: b['month_exceeded'] === true,
    dayResetsAt: SupabaseGateway.asTimestamp(b['day_resets_at']),
    monthResetsAt: SupabaseGateway.asTimestamp(b['month_resets_at']),
  };
}

export class SupabaseAiUsageRepository extends SupabaseAdminRepo {
  async getSummary(from: string, to: string): Promise<AiUsageSummary> {
    const s = (await this.gw.rpc('admin_ai_usage_summary', { p_from: from, p_to: to })) as Row;
    const totals = (s['totals'] ?? {}) as Row;
    const tiers: AiUsageSummary['tiers'] = {};
    for (const [tier, v] of Object.entries((s['tiers'] ?? {}) as Row)) {
      const t = v as Row;
      tiers[tier] = { daily: int(t['daily']), monthly: int(t['monthly']) };
    }
    return {
      from,
      to,
      totals: {
        requests: int(totals['requests']),
        completed: int(totals['completed']),
        failed: int(totals['failed']),
        released: int(totals['released']),
        tokensIn: int(totals['tokens_in']),
        tokensOut: int(totals['tokens_out']),
        tokensThought: int(totals['tokens_thought']),
        costMicros: int(totals['cost_micros']),
        users: int(totals['users']),
        avgCostPerUserMicros: int(totals['avg_cost_per_user_micros']),
      },
      byDay: ((s['by_day'] ?? []) as Row[]).map((d) => ({
        day: String(d['day']),
        requests: int(d['requests']),
        failed: int(d['failed']),
        tokensIn: int(d['tokens_in']),
        tokensOut: int(d['tokens_out']),
        costMicros: int(d['cost_micros']),
        users: int(d['users']),
      })),
      byModel: ((s['by_model'] ?? []) as Row[]).map((m) => ({
        modelId: String(m['model_id']),
        location: (m['location'] as string | null) ?? null,
        requests: int(m['requests']),
        tokensIn: int(m['tokens_in']),
        tokensOut: int(m['tokens_out']),
        costMicros: int(m['cost_micros']),
      })),
      budget: budgetFrom((s['budget'] ?? {}) as Row),
      enabled: s['enabled'] === true,
      tiers,
      pricingVerifiedAt: (s['pricing_verified_at'] as string | null) ?? undefined,
    };
  }

  async listUsers(from: string, to: string, sort: 'cost' | 'near_limit'): Promise<AiUserUsage[]> {
    const rows = await this.gw.rpcRows('admin_ai_users', { p_from: from, p_to: to, p_sort: sort, p_limit: 100 });
    return rows.map((r) => ({
      userId: SupabaseGateway.asId(r['user_id']),
      displayName: (r['display_name'] as string | null) ?? '',
      countryCode: (r['country_code'] as string | null) ?? '',
      requests: int(r['requests']),
      failed: int(r['failed']),
      tokens: int(r['tokens']),
      costMicros: int(r['cost_micros']),
      usedToday: int(r['used_today']),
      dailyLimit: int(r['daily_limit']),
      usedThisMonth: int(r['used_this_month']),
      monthlyLimit: int(r['monthly_limit']),
      credits: int(r['credits']),
      suspendedUntil: when(r['suspended_until']),
      overrideExpiresAt: when(r['override_expires_at']),
    }));
  }

  /** Null daily and monthly clear the override: the arguments are left out, and default to NULL. */
  async setQuota(userId: string, daily: number | null, monthly: number | null, expiresAt: Date | null, reason: string): Promise<void> {
    await this.requireRecentMfa('aiUsage.manage');
    await this.gw.rpc('admin_set_ai_quota', {
      p_user: userId,
      p_reason: reason,
      p_daily: daily,
      p_monthly: monthly,
      p_expires_at: expiresAt?.toISOString(),
    });
  }

  async grantCredits(idempotencyKey: string, userId: string, credits: number, reason: string): Promise<void> {
    await this.requireRecentMfa('aiUsage.manage');
    await this.gw.rpc('admin_grant_ai_credits', {
      p_idempotency_key: idempotencyKey,
      p_user: userId,
      p_credits: credits,
      p_reason: reason,
    });
  }

  /** Null lifts the suspension. */
  async setSuspension(userId: string, until: Date | null, reason: string): Promise<void> {
    await this.requireRecentMfa('aiUsage.manage');
    await this.gw.rpc('admin_set_ai_suspension', { p_user: userId, p_reason: reason, p_until: until?.toISOString() });
  }

  async setBudget(dailyMicros: number, monthlyMicros: number, reason: string): Promise<void> {
    await this.requireRecentMfa('aiUsage.controls');
    await this.gw.rpc('admin_set_ai_budget', {
      p_daily_micros: dailyMicros,
      p_monthly_micros: monthlyMicros,
      p_reason: reason,
    });
  }

  async setTier(tier: string, daily: number, monthly: number, reason: string): Promise<void> {
    await this.requireRecentMfa('aiUsage.controls');
    await this.gw.rpc('admin_set_ai_tier', { p_tier: tier, p_daily: daily, p_monthly: monthly, p_reason: reason });
  }

  async setEnabled(enabled: boolean, reason: string): Promise<void> {
    await this.requireRecentMfa('aiUsage.controls');
    await this.gw.rpc('admin_set_ai_enabled', { p_enabled: enabled, p_reason: reason });
  }
}
