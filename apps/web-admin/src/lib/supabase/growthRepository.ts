// Referrals and promos. Attributions and commissions are read from their tables;
// campaigns and promo codes change only through a four-eyes proposal (proposals.ts),
// and a pending proposal is listed beside the live rows so the console shows it.

import { AppError, ErrorCodes } from '@/mocks/errors';
import type { CampaignInput, PromoInput } from '@/mocks/repositories';
import type {
  PromoCampaign,
  ReferralAttribution,
  ReferralCampaign,
  ReferralFlagReason,
  ReferralFlaggedCase,
} from '@/mocks/types';

import { SupabaseAdminRepo, money } from './base';
import { SupabaseGateway, type Row } from './gateway';
import { pendingProposals, propose } from './proposals';

// The reasons claim_referral_code blocks with; each also raises a fraud flag, which is
// where a person reviews it (the Risk queue).
const FLAG_REASON: Record<string, ReferralFlagReason> = {
  referral_shared_device: 'device_cluster',
  referral_velocity: 'velocity_abuse',
};

export class SupabaseReferralRepository extends SupabaseAdminRepo {
  async listAttributions(country?: string): Promise<ReferralAttribution[]> {
    const rows = await this.gw.selectList(
      'referrals',
      'id, referrer_id, referee_id, country_code, attributed_at, blocked_at',
      {
        column: country ? 'country_code' : undefined,
        value: country,
        orderBy: 'attributed_at',
        ascending: false,
        limit: 200,
      },
    );
    const commissions = await this.gw.selectList(
      'referral_commissions',
      'referral_id, request_id, amount_minor, currency, status',
      { inColumn: 'referral_id', inValues: rows.map((r) => r['id']) },
    );
    const names = await this.names(rows.flatMap((r) => [r['referrer_id'], r['referee_id']]));
    const currencyOf = await this.currencies();
    return rows
      .filter((r) => !r['blocked_at'])
      .map((row) => {
        const mine = commissions.filter(
          (c) => String(c['referral_id']) === String(row['id']) && c['status'] !== 'reversed',
        );
        const country = String(row['country_code'] ?? '');
        return {
          id: String(row['id']),
          referrerId: String(row['referrer_id']),
          referrerName: SupabaseAdminRepo.nameOf(names, row['referrer_id']),
          refereeId: String(row['referee_id']),
          refereeName: SupabaseAdminRepo.nameOf(names, row['referee_id']),
          country,
          attributedAt: SupabaseGateway.asTimestamp(row['attributed_at']),
          qualifyingJobs: new Set(mine.map((c) => String(c['request_id']))).size,
          commissionEarned: money(
            mine.reduce((sum, c) => sum + SupabaseGateway.asMinorUnits(c['amount_minor']), 0),
            mine[0]?.['currency'] ?? currencyOf.get(country) ?? '',
          ),
        };
      });
  }

  /**
   * Referrals the backend blocked. A self-referral is accepted and silently blocked when it
   * is made, so these are decisions already taken: they arrive reviewed, and the fraud flag
   * each one raised is reviewed in Risk.
   */
  async listFlaggedCases(): Promise<ReferralFlaggedCase[]> {
    const rows = await this.gw.selectList(
      'referrals',
      'id, blocked_at, blocked_reason_key',
      { orderBy: 'attributed_at', ascending: false, limit: 200 },
    );
    return rows
      .filter((r) => r['blocked_at'])
      .map((row) => {
        const key = String(row['blocked_reason_key'] ?? '');
        return {
          id: String(row['id']),
          attributionId: String(row['id']),
          reason: FLAG_REASON[key] ?? 'self_referral_suspected',
          signals: [key],
          flaggedAt: SupabaseGateway.asTimestamp(row['blocked_at']),
          status: 'confirmed_abuse' as const,
        };
      });
  }

  async listCampaigns(): Promise<ReferralCampaign[]> {
    const [rows, pending] = await Promise.all([
      this.gw.selectList(
        'referral_campaigns',
        'id, country_code, name, rate_bps, currency, starts_at, ends_at, active',
        { orderBy: 'starts_at', ascending: false },
      ),
      pendingProposals(this.gw, 'referral_campaign'),
    ]);
    const now = Date.now();
    const live = rows.map((row): ReferralCampaign => {
      const endsAt = SupabaseGateway.asOptionalTimestamp(row['ends_at']);
      return {
        id: String(row['id']),
        name: String(row['name'] ?? ''),
        country: String(row['country_code']),
        rateBps: Number(row['rate_bps'] ?? 0),
        status: endsAt && endsAt.getTime() < now ? 'ended' : row['active'] ? 'active' : 'paused',
        startsAt: SupabaseGateway.asTimestamp(row['starts_at']),
        endsAt,
      };
    });
    const proposed = pending
      .filter((p) => p['target_key'] === 'new')
      .map((p): ReferralCampaign => {
        const v = (p['proposed'] ?? {}) as Row;
        return {
          id: `proposal:${String(p['id'])}`,
          name: String(v['name'] ?? ''),
          country: String(p['country_code'] ?? ''),
          rateBps: Number(v['rate_bps'] ?? 0),
          budget: v['budget_minor'] != null ? money(v['budget_minor'], v['currency']) : undefined,
          status: 'pending_approval',
          startsAt: SupabaseGateway.asTimestamp(v['starts_at'] ?? p['created_at']),
          endsAt: SupabaseGateway.asOptionalTimestamp(v['ends_at']),
        };
      });
    return [...proposed, ...live];
  }

  /** Nothing to review: a blocked referral was decided when it was made (see listFlaggedCases). */
  async reviewFlag(
    _flagId: string,
    _decision: 'dismiss' | 'confirm_abuse',
    _idempotencyKey: string,
  ): Promise<ReferralFlaggedCase> {
    throw new AppError(ErrorCodes.featureUnavailable);
  }

  async createCampaign(input: CampaignInput, idempotencyKey: string): Promise<ReferralCampaign> {
    const currency = (await this.currencies()).get(input.country) ?? input.budget?.currency;
    await propose(this.gw, idempotencyKey, 'referral_campaign', 'new', {
      name: input.name,
      rate_bps: input.rateBps,
      currency,
      budget_minor: input.budget?.amountMinor,
      starts_at: input.startsAt.toISOString(),
      ends_at: input.endsAt?.toISOString(),
    }, input.country);
    return { ...input, id: 'proposal', status: 'pending_approval' };
  }

  async pauseCampaign(campaignId: string, idempotencyKey: string): Promise<ReferralCampaign> {
    return this.setActive(campaignId, false, idempotencyKey);
  }

  async resumeCampaign(campaignId: string, idempotencyKey: string): Promise<ReferralCampaign> {
    return this.setActive(campaignId, true, idempotencyKey);
  }

  private async setActive(
    campaignId: string,
    active: boolean,
    idempotencyKey: string,
  ): Promise<ReferralCampaign> {
    const campaign = (await this.listCampaigns()).find((c) => c.id === campaignId);
    if (!campaign) throw new AppError(ErrorCodes.notFound);
    await propose(this.gw, idempotencyKey, 'referral_campaign', campaignId, { active }, campaign.country);
    return campaign;
  }

  private async currencies(): Promise<Map<string, string>> {
    const rows = await this.gw.selectList('countries', 'code, currency_code');
    return new Map(rows.map((r) => [String(r['code']), String(r['currency_code'])]));
  }
}

export class SupabasePromoRepository extends SupabaseAdminRepo {
  async listPromos(country?: string): Promise<PromoCampaign[]> {
    const [rows, pending] = await Promise.all([
      this.gw.rpcRows('admin_promo_codes', { p_country: country }),
      pendingProposals(this.gw, 'promo_code'),
    ]);
    const now = Date.now();
    const live = rows.map((row): PromoCampaign => {
      const currency = row['currency'];
      const startsAt = SupabaseGateway.asTimestamp(row['starts_at']);
      const endsAt = SupabaseGateway.asOptionalTimestamp(row['ends_at']);
      const percent = row['discount_kind'] === 'percent';
      return {
        id: String(row['id']),
        code: String(row['code']),
        country: String(row['country_code']),
        discountPercent: percent ? Number(row['discount_value']) / 100 : 0,
        discountFixed: percent ? undefined : money(row['discount_value'], currency),
        maxDiscount: row['max_discount_minor'] != null ? money(row['max_discount_minor'], currency) : undefined,
        budget: row['budget_minor'] != null ? money(row['budget_minor'], currency) : undefined,
        spent: money(row['spent_minor'], currency),
        maxRedemptions: row['max_uses'] != null ? Number(row['max_uses']) : undefined,
        redemptions: Number(row['uses'] ?? 0),
        status: endsAt && endsAt.getTime() < now
          ? 'expired'
          : !row['active']
            ? 'paused'
            : startsAt.getTime() > now
              ? 'draft'
              : 'active',
        startsAt,
        endsAt,
      };
    });
    const proposed = pending
      .filter((p) => p['target_key'] === 'new' && (!country || p['country_code'] === country))
      .map((p): PromoCampaign => {
        const v = (p['proposed'] ?? {}) as Row;
        const currency = v['currency'] ?? '';
        return {
          id: `proposal:${String(p['id'])}`,
          code: String(v['code'] ?? ''),
          country: String(p['country_code'] ?? ''),
          discountPercent: v['discount_kind'] === 'percent' ? Number(v['discount_value']) / 100 : 0,
          budget: v['budget_minor'] != null ? money(v['budget_minor'], currency) : undefined,
          spent: money(0, currency),
          maxRedemptions: v['max_uses'] != null ? Number(v['max_uses']) : undefined,
          redemptions: 0,
          status: 'pending_approval',
          startsAt: SupabaseGateway.asTimestamp(v['starts_at'] ?? p['created_at']),
          endsAt: SupabaseGateway.asOptionalTimestamp(v['ends_at']),
        };
      });
    return [...proposed, ...live];
  }

  async getPromo(promoId: string): Promise<PromoCampaign> {
    const promo = (await this.listPromos()).find((p) => p.id === promoId);
    if (!promo) throw new AppError(ErrorCodes.notFound);
    return promo;
  }

  async createPromo(input: PromoInput, idempotencyKey: string): Promise<PromoCampaign> {
    await propose(this.gw, idempotencyKey, 'promo_code', 'new', {
      code: input.code.trim().toUpperCase(),
      discount_kind: 'percent',
      // Basis points: the console takes whole percent, the server stores 1/100ths of one.
      discount_value: Math.round(input.discountPercent * 100),
      max_discount_minor: input.maxDiscount?.amountMinor,
      budget_minor: input.budget.amountMinor > 0 ? input.budget.amountMinor : undefined,
      max_uses: input.maxRedemptions > 0 ? input.maxRedemptions : undefined,
      starts_at: input.startsAt.toISOString(),
      ends_at: input.endsAt.toISOString(),
    }, input.country);
    return {
      id: 'proposal',
      code: input.code,
      country: input.country,
      discountPercent: input.discountPercent,
      maxDiscount: input.maxDiscount,
      budget: input.budget,
      spent: money(0, input.budget.currency),
      maxRedemptions: input.maxRedemptions,
      redemptions: 0,
      status: 'pending_approval',
      startsAt: input.startsAt,
      endsAt: input.endsAt,
    };
  }

  async setPromoStatus(
    promoId: string,
    status: 'active' | 'paused',
    idempotencyKey: string,
  ): Promise<PromoCampaign> {
    const promo = await this.getPromo(promoId);
    await propose(this.gw, idempotencyKey, 'promo_code', promoId, { active: status === 'active' });
    return promo;
  }
}
