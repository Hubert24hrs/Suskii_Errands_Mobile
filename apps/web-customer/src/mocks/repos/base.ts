// Shared base for the mock repositories: behavior gate, idempotency store,
// server clock and current-user resolution (mirrors _MockRepo in
// packages/suskii_data/lib/src/mock/mock_repositories.dart).

import { serverNow } from '../../lib/serverClock';
import { gate, idempotencyStore, type MockBehavior } from '../behavior';
import { AppError, ErrorCodes } from '../errors';
import type { MockDatabase } from '../fixtures';
import type { AppUser } from '../types';

/** Unsubscribe handle returned by every watch* method. */
export type Unsubscribe = () => void;

export abstract class MockRepo {
  constructor(
    protected readonly db: MockDatabase,
    protected readonly behavior: MockBehavior,
  ) {}

  protected gate(): Promise<void> {
    return gate();
  }

  /**
   * Runs a mutating call under an idempotency key, scoped like the server's: same key, same
   * operation and argsHash replays the stored result; anything else throws
   * ERR_IDEMPOTENCY_KEY_REUSED.
   */
  protected idempotent<T>(
    operation: string,
    key: string,
    argsHash: string,
    run: () => Promise<T> | T,
  ): Promise<T> {
    return idempotencyStore.run(this.behavior.currentUserId, operation, key, argsHash, run);
  }

  /** The simulated server clock — TTLs are always computed against this. */
  protected now(): Date {
    return serverNow();
  }

  protected get currentUser(): AppUser {
    const user = this.db.users[this.behavior.currentUserId];
    if (!user) throw new AppError(ErrorCodes.unauthenticated);
    return user;
  }
}
