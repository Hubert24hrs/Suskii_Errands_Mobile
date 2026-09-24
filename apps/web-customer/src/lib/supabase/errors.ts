// Maps Supabase transport/auth failures to AppError with the stable wire
// codes the UI localizes — raw exception text never reaches a screen.
// Mirrors packages/suskii_data/lib/src/supabase/supabase_error_mapping.dart.
//
// Backend functions raise `ERR_*` codes with `raise exception`, which
// PostgREST surfaces as the exception *message* (the Postgres code, e.g.
// P0001, is in `code`). The wire code is therefore recovered from the
// message text. `AppError.details` carries PostgREST's `details`, which some
// codes use for a machine-readable payload.

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
    // Insufficient privilege (RLS/grant denial) — no wire code was raised.
    case '42501':
      return new AppError(ErrorCodes.permissionDenied);
    // JWT expired/invalid.
    case 'PGRST301':
    case 'PGRST302':
    case 'PGRST303':
      return new AppError(ErrorCodes.unauthenticated);
    case 'otp_expired':
    case 'otp_disabled':
      return new AppError(ErrorCodes.otpInvalid);
    case 'over_sms_send_rate_limit':
    case 'over_email_send_rate_limit':
    case 'over_request_rate_limit':
    case 'request_timeout':
      return new AppError(ErrorCodes.otpRateLimited);
    case 'user_not_found':
    case 'session_not_found':
    case 'session_expired':
      return new AppError(ErrorCodes.unauthenticated);
  }
  // Failed fetches surface as TypeError in browsers.
  if (error instanceof TypeError) return new AppError(ErrorCodes.network);
  return new AppError(ErrorCodes.unknown);
}
