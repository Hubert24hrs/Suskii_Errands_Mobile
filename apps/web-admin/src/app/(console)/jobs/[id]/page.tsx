import type { Metadata } from 'next';
import { dict } from '@/lib/i18n';
import { JobDetailClient } from './JobDetailClient';

export const metadata: Metadata = { title: dict.jobs.title };

export default async function JobDetailPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  return <JobDetailClient jobId={id} />;
}
