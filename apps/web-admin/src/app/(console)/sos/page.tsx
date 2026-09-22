import type { Metadata } from 'next';
import { dict } from '@/lib/i18n';
import { SosClient } from './SosClient';

export const metadata: Metadata = { title: dict.sos.title };

export default function SosPage() {
  return <SosClient />;
}
