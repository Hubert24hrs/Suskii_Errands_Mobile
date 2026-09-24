// Shared helpers for the requests feature (list / new / detail). Pure
// functions only — safe to import from server or client components.

import type { Dictionary } from '@/lib/i18n/en';
import { isAppError } from '@/lib/repositories';
import type { JobStatus, ServiceCategory, Urgency } from '@/mocks/types';

type ChipTone = 'neutral' | 'info' | 'success' | 'warning' | 'error';

/** Maps any error to localized copy; unknown codes fall back to ERR_INTERNAL. */
export function errorText(dict: Dictionary, error: unknown): string {
  if (isAppError(error)) {
    const table = dict.errors as Record<string, string>;
    return table[error.code] ?? dict.errors.ERR_INTERNAL;
  }
  return dict.errors.ERR_INTERNAL;
}

/**
 * Localized job-status label. The dict does not yet carry every lifecycle
 * state (e.g. negotiating, disputed) — those fall back to the raw key.
 */
export function statusLabel(dict: Dictionary, status: JobStatus): string {
  const table = dict.requests.statuses as Record<string, string>;
  return table[status] ?? status;
}

export function statusTone(status: JobStatus): ChipTone {
  switch (status) {
    case 'published':
    case 'offers_received':
    case 'negotiating':
    case 'paid_held':
    case 'assigned':
    case 'en_route':
    case 'arrived':
    case 'in_progress':
      return 'info';
    case 'agreed':
    case 'payment_pending':
    case 'completed_by_provider':
      return 'warning';
    case 'confirmed':
    case 'settlement_pending':
    case 'settled':
    case 'closed':
      return 'success';
    case 'disputed':
      return 'error';
    default:
      return 'neutral';
  }
}

/** Category display label via dict.categories, falling back to the id. */
export function categoryLabel(
  dict: Dictionary,
  categories: ServiceCategory[],
  categoryId: string,
): string {
  const labelKey = categories.find((c) => c.id === categoryId)?.labelKey;
  const table = dict.categories as Record<string, string>;
  return (labelKey ? table[labelKey] : undefined) ?? labelKey ?? categoryId;
}

export function urgencyLabel(dict: Dictionary, urgency: Urgency): string {
  const table = dict.requests.detail.urgencyLevels as Record<string, string>;
  return table[urgency] ?? urgency;
}

/** en-NG formatting for both locales (pcm has no Intl locale data). */
export function formatDateTime(date: Date): string {
  return new Intl.DateTimeFormat('en-NG', {
    dateStyle: 'medium',
    timeStyle: 'short',
  }).format(date);
}

/** A photo chip label from a stored mock path (file name only). */
export function mediaName(path: string): string {
  const segments = path.split('/');
  return segments[segments.length - 1] || path;
}
