// Growth repositories: referral program (attributions, flagged-case review,
// campaigns) and promo campaign management.

import { AppError, ErrorCodes } from '../errors';
import type {
  Money,
  PromoCampaign,
  ReferralAttribution,
  ReferralCampaign,
  ReferralFlaggedCase,
} from '../types';
import { MockRepo } from './base';

export class MockReferralRepository extends MockRepo {
  async listAttributions(country?: string): Promise<ReferralAttribution[]> {
    await this.gate();
    this.requirePermission('referrals.read');
    return Object.values(this.db.referralAttributions).filter(
      (a) => !country || a.country === country,
    );
  }

  async listFlaggedCases(): Promise<ReferralFlaggedCase[]> {
    await this.gate();
    this.requirePermission('referrals.read');
    return Object.values(this.db.referralFlags);
  }

  async listCampaigns(): Promise<ReferralCampaign[]> {
    await this.gate();
    this.requirePermission('referrals.read');
    return Object.values(this.db.referralCampaigns);
  }

  /** Review a flagged case: dismiss it or confirm abuse. Audit-logged. */
  async reviewFlag(
    flagId: string,
    decision: 'dismiss' | 'confirm_abuse',
    idempotencyKey: string,
  ): Promise<ReferralFlaggedCase> {
    await this.gate();
    const admin = this.requirePermission('referrals.manage');
    return this.idempotent(`referrals.review:${flagId}`, idempotencyKey, decision, () => {
      const flag = this.db.referralFlags[flagId];
      if (!flag) throw new AppError(ErrorCodes.unknown);
      if (flag.status !== 'open') throw new AppError(ErrorCodes.alreadyReviewed);
      flag.status = decision === 'dismiss' ? 'dismissed' : 'confirmed_abuse';
      flag.reviewedByAdminId = admin.id;
      this.audit(`referrals.review_${decision}`, `referral_flag/${flagId}`);
      return flag;
    });
  }

  async createCampaign(
    input: {
      name: string;
      country: string;
      referrerReward: Money;
      refereeReward: Money;
      startsAt: Date;
      endsAt?: Date;
    },
    idempotencyKey: string,
  ): Promise<ReferralCampaign> {
    await this.gate();
    this.requirePermission('referrals.manage');
    return this.idempotent(
      'referrals.create_campaign',
      idempotencyKey,
      JSON.stringify(input),
      () => {
        const campaign: ReferralCampaign = {
          id: `rc-${globalThis.crypto.randomUUID().slice(0, 8)}`,
          name: input.name,
          country: input.country,
          referrerReward: input.referrerReward,
          refereeReward: input.refereeReward,
          status: 'active',
          startsAt: input.startsAt,
          endsAt: input.endsAt,
        };
        this.db.referralCampaigns[campaign.id] = campaign;
        this.audit('referrals.create_campaign', `referral_campaign/${campaign.id}`, input.name);
        return campaign;
      },
    );
  }

  async pauseCampaign(campaignId: string, idempotencyKey: string): Promise<ReferralCampaign> {
    await this.gate();
    this.requirePermission('referrals.manage');
    return this.idempotent(`referrals.pause:${campaignId}`, idempotencyKey, '', () => {
      const campaign = this.db.referralCampaigns[campaignId];
      if (!campaign) throw new AppError(ErrorCodes.unknown);
      if (campaign.status !== 'active') throw new AppError(ErrorCodes.invalidState);
      campaign.status = 'paused';
      this.audit('referrals.pause_campaign', `referral_campaign/${campaignId}`);
      return campaign;
    });
  }

  /** Resume a paused campaign (symmetric to pauseCampaign). Audit-logged. */
  async resumeCampaign(campaignId: string, idempotencyKey: string): Promise<ReferralCampaign> {
    await this.gate();
    this.requirePermission('referrals.manage');
    return this.idempotent(`referrals.resume:${campaignId}`, idempotencyKey, '', () => {
      const campaign = this.db.referralCampaigns[campaignId];
      if (!campaign) throw new AppError(ErrorCodes.unknown);
      if (campaign.status !== 'paused') throw new AppError(ErrorCodes.invalidState);
      campaign.status = 'active';
      this.audit('referrals.resume_campaign', `referral_campaign/${campaignId}`);
      return campaign;
    });
  }
}

export interface PromoInput {
  code: string;
  country: string;
  discountPercent: number;
  maxDiscount?: Money;
  budget: Money;
  maxRedemptions: number;
  startsAt: Date;
  endsAt: Date;
}

export class MockPromoRepository extends MockRepo {
  async listPromos(country?: string): Promise<PromoCampaign[]> {
    await this.gate();
    this.requirePermission('promos.read');
    return Object.values(this.db.promos).filter((p) => !country || p.country === country);
  }

  async getPromo(promoId: string): Promise<PromoCampaign> {
    await this.gate();
    this.requirePermission('promos.read');
    const promo = this.db.promos[promoId];
    if (!promo) throw new AppError(ErrorCodes.unknown);
    return promo;
  }

  async createPromo(input: PromoInput, idempotencyKey: string): Promise<PromoCampaign> {
    await this.gate();
    this.requirePermission('promos.manage');
    return this.idempotent('promos.create', idempotencyKey, JSON.stringify(input), () => {
      const promo: PromoCampaign = {
        id: `promo-${globalThis.crypto.randomUUID().slice(0, 8)}`,
        code: input.code,
        country: input.country,
        discountPercent: input.discountPercent,
        maxDiscount: input.maxDiscount,
        budget: input.budget,
        spent: { amountMinor: 0, currency: input.budget.currency },
        maxRedemptions: input.maxRedemptions,
        redemptions: 0,
        status: 'draft',
        startsAt: input.startsAt,
        endsAt: input.endsAt,
      };
      this.db.promos[promo.id] = promo;
      this.audit('promos.create', `promo/${promo.id}`, input.code);
      return promo;
    });
  }

  /** Activate or pause a campaign (draft → active, active ⇄ paused). */
  async setPromoStatus(
    promoId: string,
    status: 'active' | 'paused',
    idempotencyKey: string,
  ): Promise<PromoCampaign> {
    await this.gate();
    this.requirePermission('promos.manage');
    return this.idempotent(`promos.status:${promoId}`, idempotencyKey, status, () => {
      const promo = this.db.promos[promoId];
      if (!promo) throw new AppError(ErrorCodes.unknown);
      if (promo.status === 'expired') throw new AppError(ErrorCodes.invalidState);
      if (status === 'paused' && promo.status !== 'active') {
        throw new AppError(ErrorCodes.invalidState);
      }
      promo.status = status;
      this.audit(`promos.${status === 'active' ? 'activate' : 'pause'}`, `promo/${promoId}`);
      return promo;
    });
  }
}
