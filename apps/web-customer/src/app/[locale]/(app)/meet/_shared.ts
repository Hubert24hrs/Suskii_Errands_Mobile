import type { Dictionary } from '@/lib/i18n/en';
import type { GeoPoint, Meetup } from '@/mocks/types';

export const card =
  'rounded-lg border border-outline bg-surface-raised p-xl dark:border-outline-dark dark:bg-surface-dark-raised';
export const primaryButton =
  'rounded-md bg-brand-primary px-lg py-sm text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong disabled:opacity-50';
export const secondaryButton =
  'rounded-md border border-outline px-lg py-sm text-label-large text-ink-primary transition-colors duration-normal ease-standard hover:bg-surface-muted disabled:opacity-50 dark:border-outline-dark dark:text-ink-dark-primary dark:hover:bg-surface-dark-muted';
export const inputClasses =
  'w-full rounded-md border border-outline bg-surface-raised px-md py-sm text-body-large text-ink-primary outline-none transition-colors duration-normal ease-standard focus:border-brand-primary placeholder:text-ink-secondary dark:border-outline-dark dark:bg-surface-dark-raised dark:text-ink-dark-primary dark:placeholder:text-ink-dark-secondary';

export function fill(template: string, values: Record<string, string | number>): string {
  return template.replace(/\{(\w+)\}/g, (_, key: string) => String(values[key] ?? ''));
}

export function meetupWhen(iso: string): string {
  return new Date(iso).toLocaleString(undefined, {
    weekday: 'short',
    day: 'numeric',
    month: 'short',
    hour: '2-digit',
    minute: '2-digit',
  });
}

export function spotsLeft(m: Meetup): number {
  return Math.max(0, m.capacity - m.attendeeCount);
}

export function badge(dict: Dictionary, m: Meetup): string {
  if (m.status === 'cancelled') return dict.meet.cancelled;
  if (m.isHost) return dict.meet.youHost;
  if (m.isAttending) return dict.meet.youGoing;
  if (m.attendeeCount >= m.capacity) return dict.meet.full;
  return fill(dict.meet.spotsLeft, { count: spotsLeft(m) });
}

/** The browser's position, once, to sort and filter; never stored. */
export function currentPosition(): Promise<GeoPoint | undefined> {
  return new Promise((resolve) => {
    if (typeof navigator === 'undefined' || !navigator.geolocation) return resolve(undefined);
    navigator.geolocation.getCurrentPosition(
      (p) => resolve({ latitude: p.coords.latitude, longitude: p.coords.longitude }),
      () => resolve(undefined),
      { timeout: 10_000, maximumAge: 300_000 },
    );
  });
}
