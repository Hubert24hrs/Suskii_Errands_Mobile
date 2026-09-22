'use client';

// Shared helpers for the jobs module (list + detail).

import { dict } from '@/lib/i18n';
import type { JobAdminView, JobStatus } from '@/mocks/types';
import { StatusChip } from '@/components/StatusChip';

export function jobStatusLabel(status: JobStatus | 'created'): string {
  return (dict.jobs.statuses as Record<string, string>)[status] ?? status;
}

export function jobStatusChip(status: JobStatus) {
  const tone =
    status === 'confirmed'
      ? 'success'
      : status === 'disputed' || status === 'cancelled'
        ? 'error'
        : status === 'agreed' || status === 'payment_pending'
          ? 'warning'
          : status === 'paid_held' || status === 'in_progress' || status === 'negotiating'
            ? 'info'
            : 'neutral';
  return <StatusChip label={jobStatusLabel(status)} tone={tone} />;
}

/**
 * The admin job view carries a short categoryId (e.g. 'errands') while
 * dict.categories is keyed by catalog labelKey (e.g. 'catErrandsDelivery'),
 * and the admin mocks expose no catalog repository — so the mapping is a
 * co-located table, with the raw categoryId as fallback.
 */
const CATEGORY_ID_TO_LABEL_KEY: Record<string, keyof typeof dict.categories> = {
  errands: 'catErrandsDelivery',
  delivery: 'catDocumentDelivery',
  transport: 'catTransportation',
  moving: 'catMoving',
  custom: 'catCustom',
};

export function categoryLabel(categoryId: string): string {
  const labelKey = CATEGORY_ID_TO_LABEL_KEY[categoryId];
  return labelKey ? dict.categories[labelKey] : categoryId;
}

/** The detail dict has no country column label — reuse the directory one. */
export function countryLabel(country: string): string {
  return (dict.dashboard.countries as Record<string, string>)[country] ?? country;
}

/** "Updated" = the latest timeline event, falling back to creation. */
export function jobUpdatedAt(job: JobAdminView): Date {
  return job.timeline.length > 0 ? job.timeline[job.timeline.length - 1].at : job.createdAt;
}
