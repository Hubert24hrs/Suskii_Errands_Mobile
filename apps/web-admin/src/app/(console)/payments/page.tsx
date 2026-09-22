import type { Metadata } from 'next';
import { dict } from '@/lib/i18n';
import { PaymentsClient } from './PaymentsClient';

export const metadata: Metadata = { title: dict.payments.title };

export default function PaymentsPage() {
  return <PaymentsClient />;
}
