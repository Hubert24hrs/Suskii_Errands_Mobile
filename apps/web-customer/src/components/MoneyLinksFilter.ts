'use client';

import { useQuery } from '@tanstack/react-query';
import { bootstrapRepository } from '@/lib/repositories';
import { paysDirectly } from '@/mocks/types';

/** Pages that hold money moved through the site. In a direct-payment country
 * (ADR-0025) nothing is paid or earned here, so they have nothing in them. */
const MONEY_HREFS: ReadonlySet<string> = new Set(['/wallet', '/promos', '/referrals', '/disputes']);

/** Whether a link to [href] belongs in this country's menus. */
export function useShowsMoneyLink(): (href: string) => boolean {
  const bootstrap = useQuery({
    queryKey: ['bootstrap'],
    queryFn: () => bootstrapRepository.getBootstrap(),
  });
  const direct = paysDirectly(bootstrap.data?.countryPack);
  return (href: string) => !direct || !MONEY_HREFS.has(href);
}
