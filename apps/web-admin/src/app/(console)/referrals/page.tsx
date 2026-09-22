import type { Metadata } from 'next';
import { dict } from '@/lib/i18n';
import { ReferralsClient } from './ReferralsClient';

export const metadata: Metadata = { title: dict.referrals.title };

export default function ReferralsPage() {
  return <ReferralsClient />;
}
