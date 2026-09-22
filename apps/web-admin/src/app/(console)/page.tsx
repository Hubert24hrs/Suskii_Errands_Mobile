import type { Metadata } from 'next';
import { dict } from '@/lib/i18n';
import { DashboardClient } from './DashboardClient';

export const metadata: Metadata = { title: dict.dashboard.title };

export default function DashboardPage() {
  return <DashboardClient />;
}
