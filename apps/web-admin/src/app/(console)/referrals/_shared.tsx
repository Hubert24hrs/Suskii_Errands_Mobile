'use client';

// Shared helpers for the referrals module.

import { dict } from '@/lib/i18n';
import type { ReferralCampaign, ReferralFlaggedCase } from '@/mocks/types';
import { StatusChip } from '@/components/StatusChip';

/** Country → ISO 4217 for the money inputs in the campaign form. */
export const COUNTRY_CURRENCY: Record<string, string> = {
  NG: 'NGN',
  KE: 'KES',
  GH: 'GHS',
  ZA: 'ZAR',
  UG: 'UGX',
};

export const COUNTRIES = Object.keys(COUNTRY_CURRENCY);

export function countryLabel(country: string): string {
  return (dict.dashboard.countries as Record<string, string>)[country] ?? country;
}

export function campaignStatusChip(status: ReferralCampaign['status']) {
  const label =
    status === 'active'
      ? dict.referrals.campaign.statusActive
      : status === 'paused'
        ? dict.referrals.campaign.statusPaused
        : dict.referrals.campaign.statusEnded;
  const tone = status === 'active' ? 'success' : status === 'paused' ? 'warning' : 'neutral';
  return <StatusChip label={label} tone={tone} />;
}

export function flagStatusChip(status: ReferralFlaggedCase['status']) {
  const label = (dict.referrals.statuses as Record<string, string>)[status] ?? status;
  const tone =
    status === 'confirmed_abuse' ? 'error' : status === 'dismissed' ? 'success' : 'warning';
  return <StatusChip label={label} tone={tone} />;
}
