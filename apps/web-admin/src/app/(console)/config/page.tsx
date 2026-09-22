import type { Metadata } from 'next';
import { dict } from '@/lib/i18n';
import { ConfigClient } from './ConfigClient';

export const metadata: Metadata = { title: dict.config.title };

export default function ConfigPage() {
  return <ConfigClient />;
}
