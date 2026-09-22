import type { Metadata } from 'next';
import { dict } from '@/lib/i18n';
import { PromosClient } from './PromosClient';

export const metadata: Metadata = { title: dict.promos.title };

export default function PromosPage() {
  return <PromosClient />;
}
