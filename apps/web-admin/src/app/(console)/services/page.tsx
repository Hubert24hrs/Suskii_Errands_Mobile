import type { Metadata } from 'next';
import { dict } from '@/lib/i18n';
import { ServicesClient } from './ServicesClient';

export const metadata: Metadata = { title: dict.services.title };

export default function ServicesPage() {
  return <ServicesClient />;
}
