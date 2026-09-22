import 'dart:io';

import 'package:supabase/supabase.dart';
import 'package:suskii_core/suskii_core.dart';

/// Maps Supabase transport/auth failures to [AppError] with the stable wire
/// codes the UI localizes — raw exception text never reaches a screen.
///
/// Backend functions raise `ERR_*` codes with `raise exception`, which
/// PostgREST surfaces as the exception *message* (the Postgres code, e.g.
/// P0001, is in [PostgrestException.code]). The wire code is therefore
/// recovered from the message text. [AppError.details] carries PostgREST's
/// `details`, which some codes use for a machine-readable payload (e.g.
/// ERR_CONTENT_NOT_ALLOWED's rule key, ERR_PROOF_REQUIRED's missing list).
AppError mapSupabaseError(Object error) {
  if (error is AppError) return error;
  if (error is PostgrestException) return _mapPostgrest(error);
  if (error is AuthException) return _mapAuth(error);
  if (error is SocketException || error is HttpException) {
    return const AppError(ErrorCodes.network);
  }
  return const AppError(ErrorCodes.unknown);
}

final RegExp _wireCode = RegExp(r'ERR_[A-Z0-9_]+');

AppError _mapPostgrest(PostgrestException e) {
  final wire = _wireCode.stringMatch(e.message);
  if (wire != null) {
    return AppError(wire, details: e.details?.toString());
  }
  return switch (e.code) {
    // Insufficient privilege (RLS/grant denial) — no wire code was raised.
    '42501' => const AppError(ErrorCodes.permissionDenied),
    // JWT expired/invalid.
    'PGRST301' ||
    'PGRST302' ||
    'PGRST303' => const AppError(ErrorCodes.unauthenticated),
    _ => const AppError(ErrorCodes.unknown),
  };
}

AppError _mapAuth(AuthException e) {
  if (e is AuthRetryableFetchException)
    return const AppError(ErrorCodes.network);
  final wire = _wireCode.stringMatch(e.message);
  if (wire != null) return AppError(wire);
  return switch (e.code) {
    'otp_expired' || 'otp_disabled' => const AppError(ErrorCodes.otpInvalid),
    'over_sms_send_rate_limit' ||
    'over_email_send_rate_limit' ||
    'over_request_rate_limit' ||
    'request_timeout' => const AppError(ErrorCodes.otpRateLimited),
    'user_not_found' ||
    'session_not_found' ||
    'session_expired' => const AppError(ErrorCodes.unauthenticated),
    _ => const AppError(ErrorCodes.unknown),
  };
}
