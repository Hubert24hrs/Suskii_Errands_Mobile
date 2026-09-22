import type { Metadata } from 'next';
import { dict } from '@/lib/i18n';
import { AuditClient } from './AuditClient';

export const metadata: Metadata = { title: dict.audit.title };

export default function AuditPage() {
  return <AuditClient />;
}
