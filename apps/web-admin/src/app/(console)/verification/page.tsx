import type { Metadata } from 'next';
import { dict } from '@/lib/i18n';
import { VerificationClient } from './VerificationClient';

export const metadata: Metadata = { title: dict.verification.title };

export default function VerificationPage() {
  return <VerificationClient />;
}
