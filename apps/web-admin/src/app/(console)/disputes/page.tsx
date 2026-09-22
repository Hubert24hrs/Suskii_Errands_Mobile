import type { Metadata } from 'next';
import { dict } from '@/lib/i18n';
import { DisputesClient } from './DisputesClient';

export const metadata: Metadata = { title: dict.disputes.title };

export default function DisputesPage() {
  return <DisputesClient />;
}
