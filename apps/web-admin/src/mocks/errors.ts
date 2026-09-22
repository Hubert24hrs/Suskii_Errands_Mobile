// Stable error codes for the admin console mock layer — the core set from
// apps/web-customer (mirroring packages/suskii_core/lib/src/errors.dart)
// plus admin-session and approval-flow codes. The UI maps code →
// localization key, never raw text.

export const ErrorCodes = {
  network: 'ERR_NETWORK',
  unknown: 'ERR_UNKNOWN',
  internal: 'ERR_INTERNAL',
  unauthenticated: 'ERR_UNAUTHENTICATED',
  permissionDenied: 'ERR_PERMISSION_DENIED',
  idempotencyKeyReused: 'ERR_IDEMPOTENCY_KEY_REUSED',
  invalidState: 'ERR_INVALID_STATE',

  // Admin session
  sessionExpired: 'ERR_SESSION_EXPIRED',
  reauthRequired: 'ERR_REAUTH_REQUIRED',
  mfaRequired: 'ERR_MFA_REQUIRED',
  mfaInvalid: 'ERR_MFA_INVALID',

  // Approval flows
  approvalRequired: 'ERR_APPROVAL_REQUIRED',
  alreadyReviewed: 'ERR_ALREADY_REVIEWED',
} as const;

export type ErrorCode = (typeof ErrorCodes)[keyof typeof ErrorCodes];

/** Error type surfaced to the app. `messageKey` is a localization key. */
export class AppError extends Error {
  readonly code: ErrorCode;
  readonly messageKey?: string;
  readonly details?: unknown;

  constructor(code: ErrorCode, options?: { messageKey?: string; details?: unknown }) {
    super(code);
    this.name = 'AppError';
    this.code = code;
    this.messageKey = options?.messageKey;
    this.details = options?.details;
  }

  override toString(): string {
    return `AppError(${this.code})`;
  }
}

export function isAppError(error: unknown, code?: ErrorCode): error is AppError {
  return (
    error instanceof AppError && (code === undefined || error.code === code)
  );
}
