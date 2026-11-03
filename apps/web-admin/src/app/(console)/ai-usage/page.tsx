import type { Metadata } from 'next';
import { dict } from '@/lib/i18n';
import { AiUsageClient } from './AiUsageClient';

export const metadata: Metadata = { title: dict.aiUsage.title };

export default function AiUsagePage() {
  return <AiUsageClient />;
}
