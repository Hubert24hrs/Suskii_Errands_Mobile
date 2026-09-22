import type { Metadata } from 'next';
import { dict } from '@/lib/i18n';
import { DisputeDetailClient } from './DisputeDetailClient';

export const metadata: Metadata = { title: dict.disputes.title };

export default async function DisputeDetailPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  return <DisputeDetailClient disputeId={id} />;
}
