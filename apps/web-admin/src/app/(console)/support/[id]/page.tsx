import type { Metadata } from 'next';
import { dict } from '@/lib/i18n';
import { SupportThreadClient } from './SupportThreadClient';

export const metadata: Metadata = { title: dict.support.title };

export default async function SupportThreadPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  return <SupportThreadClient ticketId={id} />;
}
