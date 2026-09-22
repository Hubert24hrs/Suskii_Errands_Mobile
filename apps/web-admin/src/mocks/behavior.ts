// Tunables + shared plumbing for the admin mock layer: simulated latency,
// offline/failure injection, the idempotency store, a tiny event emitter,
// and the integer money rounding used by server-style quotes (mirrors
// apps/web-customer/src/mocks/behavior.ts). All money math lives in the
// mock layer — never in components.

import { AppError, ErrorCodes } from './errors';

/** Sliding admin session lifetime (30 minutes, checked on every call). */
export const SESSION_TTL_MS = 30 * 60_000;
/** Sensitive mutations require reauth() within this window (5 minutes). */
export const REAUTH_WINDOW_MS = 5 * 60_000;
/** Document-view grants are short-lived (60 seconds). */
export const DOCUMENT_VIEW_TTL_MS = 60_000;

export interface MockBehavior {
  latencyMs: number;
  offline: boolean;
  failNextCalls: number;
  /** Signed-in admin persona (demo hook — see sessionRepository.switchPersona). */
  currentAdminId: string;
  /** Skew of the simulated server clock vs the device clock. */
  serverClockSkewMs: number;
  /** Interval between location pings appended to an active SOS trail. */
  sosTickIntervalMs: number;
  /** The next MFA attempt fails (any code) — demos the failure path. */
  failNextMfa: boolean;
  /**
   * Withdrawals at or above these amounts (minor units per currency)
   * require the two-person flow: approveWithdrawal refuses them with
   * ERR_APPROVAL_REQUIRED so the UI falls back to requestApproval →
   * confirmApproval.
   */
  twoPersonApprovalThresholds: Record<string, number>;
}

export const mockBehavior: MockBehavior = {
  latencyMs: 450,
  offline: false,
  failNextCalls: 0,
  currentAdminId: 'admin-amina',
  serverClockSkewMs: 7000,
  sosTickIntervalMs: 4000,
  failNextMfa: false,
  twoPersonApprovalThresholds: { NGN: 2_500_000, KES: 500_000, GHS: 500_000 },
};

export function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** Simulated network gate: latency, then offline/failure injection. */
export async function gate(): Promise<void> {
  await sleep(mockBehavior.latencyMs);
  if (mockBehavior.offline) {
    throw new AppError(ErrorCodes.network);
  }
  if (mockBehavior.failNextCalls > 0) {
    mockBehavior.failNextCalls--;
    throw new AppError(ErrorCodes.internal);
  }
}

/** Minimal multicast emitter standing in for backend broadcast streams. */
export class Emitter<T> {
  private readonly listeners = new Set<(value: T) => void>();

  subscribe(listener: (value: T) => void): () => void {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }

  emit(value: T): void {
    for (const listener of [...this.listeners]) listener(value);
  }
}

/**
 * Stored results of completed mutating calls, keyed `'$operation:$key'`,
 * together with the argument hash of the original call. The same key with
 * the SAME payload replays the first result; the same key with a DIFFERENT
 * payload is refused with ERR_IDEMPOTENCY_KEY_REUSED. Only successes are
 * stored.
 */
export class IdempotencyStore {
  private readonly results = new Map<string, { argsHash: string; value: unknown }>();

  async run<T>(
    operation: string,
    key: string,
    argsHash: string,
    fn: () => Promise<T> | T,
  ): Promise<T> {
    const storageKey = `${operation}:${key}`;
    const cached = this.results.get(storageKey);
    if (cached !== undefined) {
      if (cached.argsHash !== argsHash) {
        throw new AppError(ErrorCodes.idempotencyKeyReused);
      }
      return cached.value as T;
    }
    const value = await fn();
    this.results.set(storageKey, { argsHash, value });
    return value;
  }
}

/** Integer rounding exactly as the server's ledger does it: half-even. */
export function roundHalfEven(numerator: number, denominator: number): number {
  const quotient = Math.trunc(numerator / denominator);
  const remainder = numerator % denominator;
  const twice = remainder * 2;
  if (twice > denominator) return quotient + 1;
  if (twice < denominator) return quotient;
  return quotient % 2 === 0 ? quotient : quotient + 1;
}
