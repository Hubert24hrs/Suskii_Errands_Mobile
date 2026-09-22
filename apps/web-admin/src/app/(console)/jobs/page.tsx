import type { Metadata } from 'next';
import { dict } from '@/lib/i18n';
import { JobsClient } from './JobsClient';

export const metadata: Metadata = { title: dict.jobs.title };

export default function JobsPage() {
  return <JobsClient />;
}
