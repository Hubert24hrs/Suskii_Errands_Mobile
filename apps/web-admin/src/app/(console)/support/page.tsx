import type { Metadata } from 'next';
import { dict } from '@/lib/i18n';
import { SupportClient } from './SupportClient';

export const metadata: Metadata = { title: dict.support.title };

export default function SupportPage() {
  return <SupportClient />;
}
