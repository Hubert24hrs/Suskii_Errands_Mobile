import type { Metadata } from 'next';
import { dict } from '@/lib/i18n';
import { AnalyticsClient } from './AnalyticsClient';

export const metadata: Metadata = { title: dict.analytics.title };

export default function AnalyticsPage() {
  return <AnalyticsClient />;
}
