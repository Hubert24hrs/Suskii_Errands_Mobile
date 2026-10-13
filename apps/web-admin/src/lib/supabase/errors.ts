// Maps Supabase transport/auth failures to AppError with the stable wire codes
// the console localises — raw exception text never reaches a screen. Mirrors
// apps/web-customer/src/lib/supabase/errors.ts. Backend functions raise
// `ERR_*` codes, which PostgREST surfaces as the exception message.

import { AppError, ErrorCodes, type ErrorCode } from '@/mocks/errors';

const WIRE_CODE = /ERR_[A-Z0-9_]+/;

interface SupabaseErrorLike {
  message?: unknown;
  code?: unknown;
  details?: unknown;
}

export function mapSupabaseError(error: unknown): AppError {
  if (error instanceof AppError) return error;
  const e = (error ?? {}) as SupabaseErrorLike;
  const message = typeof e.message === 'string' ? e.message : '';
  const wire = message.match(WIRE_CODE)?.[0] as ErrorCode | undefined;
  if (wire) {
    return new AppError(wire, {
      details: typeof e.details === 'string' ? e.details : undefined,
    });
  }
  switch (typeof e.code === 'string' ? e.code : '') {
    case '42501':
    case '403':
      return new AppError(ErrorCodes.permissionDenied);
    case 'PGRST301':
    case 'PGRST302':
    case 'PGRST303':
    case '401':
    case 'session_not_found':
    case 'session_expired':
    case 'refresh_token_not_found':
      return new AppError(ErrorCodes.unauthenticated);
    case 'invalid_credentials':
    case 'user_not_found':
      return new AppError(ErrorCodes.unauthenticated);
    case 'mfa_verification_failed':
    case 'mfa_challenge_expired':
      return new AppError(ErrorCodes.mfaInvalid);
    case 'over_request_rate_limit':
    case 'too_many_enrolled_mfa_factors':
      return new AppError(ErrorCodes.invalidState);
  }
  if (error instanceof TypeError) return new AppError(ErrorCodes.network);
  return new AppError(ErrorCodes.unknown);
}
