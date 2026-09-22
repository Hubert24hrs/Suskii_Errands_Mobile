// Tunables + shared plumbing for the mock layer: simulated latency, offline
// mode, failure injection, the idempotency store, a tiny event emitter, and
// the server-side money simulation (mirrors packages/suskii_data mock
// behavior/server_sim). All money math lives here — never in components.

import { AppError, ErrorCodes } from './errors';
import type { Money, PriceBreakdown } from './types';

export interface MockBehavior {
  latencyMs: number;
  offline: boolean;
  failNextCalls: number;
  currentUserId: string;
  /** Liveness capture fails with a reason key — demos the failure path. */
  failLiveness: boolean;
  /** Simulated review time before a verification session flips to verified. */
  kycReviewDelayMs: number;
  /**
   * Skew of the simulated server clock vs the device clock (bootstrap
   * serverTime). Non-zero by default to prove the server-clock mechanism.
   */
  serverClockSkewMs: number;
  /** Overrides per-category offer TTL. Null → category's offerTtlSeconds. */
  offerTtlOverrideMs: number | null;
  /** Simulated gateway delay before an initialized payment confirms. */
  paymentConfirmDelayMs: number;
  /** The next initialized payment confirms as FAILED instead of HELD. */
  failNextPayment: boolean;
  /** Simulated ops-review delay before a dispute resolves. */
  disputeResolveDelayMs: number;
  /** Simulated delay before AI triage replies to a support ticket. */
  supportTriageDelayMs: number;
  /** Staggered arrival delays for simulated incoming offers. */
  offerArrivalDelaysMs: number[];
  /** Delay before the mock provider responds to a customer counter-offer. */
  providerResponseDelayMs: number;
  /**
   * Finance-approval thresholds for withdrawals, in minor units per
   * currency (configurable per country, like the backend rule).
   */
  withdrawalApprovalThresholds: Record<string, number>;
}

export const mockBehavior: MockBehavior = {
  latencyMs: 450,
  offline: false,
  failNextCalls: 0,
  currentUserId: 'user-ada',
  failLiveness: false,
  kycReviewDelayMs: 4000,
  serverClockSkewMs: 7000,
  offerTtlOverrideMs: null,
  paymentConfirmDelayMs: 3000,
  failNextPayment: false,
  disputeResolveDelayMs: 5000,
  supportTriageDelayMs: 2000,
  offerArrivalDelaysMs: [5000, 9000, 13000],
  providerResponseDelayMs: 4000,
  withdrawalApprovalThresholds: { NGN: 50000000, USD: 50000 },
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

/** Minimal multicast emitter standing in for the Dart broadcast streams. */
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
 * together with the argument hash of the original call. Mirrors the
 * backend's idempotency layer (spike S-10): the same key with the SAME
 * payload replays the first result; the same key with a DIFFERENT payload
 * is refused with ERR_IDEMPOTENCY_KEY_REUSED. Only successes are stored.
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

/**
 * Integer-math money rounding exactly as the server's ledger does it:
 * round half-even at minor units.
 */
export function roundHalfEven(numerator: number, denominator: number): number {
  const quotient = Math.trunc(numerator / denominator);
  const remainder = numerator % denominator;
  const twice = remainder * 2;
  if (twice > denominator) return quotient + 1;
  if (twice < denominator) return quotient;
  return quotient % 2 === 0 ? quotient : quotient + 1;
}

/** Server-side quote simulation (commission rate snapshotted per job). */
export function simulateQuote(
  gross: Money,
  options?: {
    commissionRateBps?: number;
    estimatedGatewayFee?: Money;
    tip?: Money;
  },
): PriceBreakdown {
  const commissionRateBps = options?.commissionRateBps ?? 1250;
  const commission: Money = {
    amountMinor: roundHalfEven(gross.amountMinor * commissionRateBps, 10000),
    currency: gross.currency,
  };
  const net: Money = {
    amountMinor: gross.amountMinor - commission.amountMinor,
    currency: gross.currency,
  };
  const gateway = options?.estimatedGatewayFee?.amountMinor ?? 0;
  const tip = options?.tip?.amountMinor ?? 0;
  return {
    gross,
    platformCommission: commission,
    net,
    providerPayout: {
      amountMinor: net.amountMinor - gateway + tip,
      currency: gross.currency,
    },
    commissionRateBps,
    estimatedGatewayFee: options?.estimatedGatewayFee,
    tip: options?.tip,
  };
}
