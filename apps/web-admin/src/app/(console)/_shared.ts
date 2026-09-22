'use client';

// Shared helpers for the console shell and the first admin modules. The
// permission helper wraps the exported PERMISSIONS matrix (single source of
// truth — hiding CTAs is UX, not security; the repos re-check server-side).

import { useQuery } from '@tanstack/react-query';
import { dict } from '@/lib/i18n';
import {
  PERMISSIONS,
  isAppError,
  sessionRepository,
  type AdminAction,
} from '@/mocks/repositories';
import type { AdminRole } from '@/mocks/types';

/** Client-side mirror of the role × action matrix for CTA/nav gating. */
export function can(role: AdminRole, action: AdminAction): boolean {
  return PERMISSIONS[action].includes(role);
}

export function roleLabel(role: AdminRole): string {
  return dict.roles[role];
}

/** Maps any error to dict copy; unknown codes fall back to ERR_INTERNAL. */
export function errorText(error: unknown): string {
  if (isAppError(error)) {
    const table = dict.errors as Record<string, string>;
    return table[error.code] ?? dict.errors.ERR_INTERNAL;
  }
  return dict.errors.ERR_INTERNAL;
}

/** True when the error means the console must return to /sign-in. */
export function isSessionError(error: unknown): boolean {
  return (
    isAppError(error, 'ERR_SESSION_EXPIRED') || isAppError(error, 'ERR_UNAUTHENTICATED')
  );
}

/** en-GB timestamps for the internal console. */
export function formatDateTime(date: Date): string {
  return new Intl.DateTimeFormat('en-GB', {
    dateStyle: 'medium',
    timeStyle: 'short',
  }).format(date);
}

/** The signed-in admin session (null = signed out). Shared query cache. */
export function useAdminSession() {
  return useQuery({
    queryKey: ['admin', 'session'],
    queryFn: () => sessionRepository.getSession(),
    staleTime: 30_000,
  });
}
