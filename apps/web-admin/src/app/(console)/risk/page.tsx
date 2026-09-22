import type { Metadata } from 'next';
import { dict } from '@/lib/i18n';
import { RiskClient } from './RiskClient';

export const metadata: Metadata = { title: dict.risk.title };

export default function RiskPage() {
  return <RiskClient />;
}
