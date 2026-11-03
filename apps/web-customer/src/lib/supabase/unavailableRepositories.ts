// The two customer surfaces with no backend yet, as they must behave against a real one:
// honest about it, never the mock's invented data (audit 2026-10-13, Z.15 on the web).

import { AppError, ErrorCodes } from '@/mocks/errors';
import type { AiUsage, ConciergeConversation, ConciergeMessage, Promo } from '@/mocks/types';
import { mapSupabaseError } from './errors';
import type { SupabaseGateway } from './gateway';
import { aiUsageFromJson } from './mappers';
import type { Unsubscribe } from '@/mocks/repos/base';

/**
 * A promo code is applied at payment (`start_payment`'s `p_promo_code`, previewed by
 * `preview_promo` on the pay screen). An account-level voucher wallet does not exist and is a
 * client decision (CR-20260923-04), so the wallet is empty and redeeming outside a job says so.
 */
export class SupabasePromoRepository {
  async getPromos(): Promise<Promo[]> {
    return [];
  }

  async redeemPromo(_code: string, _idempotencyKey: string): Promise<Promo> {
    throw new AppError(ErrorCodes.featureUnavailable);
  }
}

/**
 * The website's concierge is not wired to the `concierge` function yet, so the turns say it is
 * unavailable. The allowance is real: it is the same `my_ai_usage` the app shows.
 */
export class SupabaseConciergeRepository {
  constructor(private readonly gateway: SupabaseGateway) {}

  async getUsage(): Promise<AiUsage> {
    try {
      return aiUsageFromJson((await this.gateway.rpc('my_ai_usage')) as Record<string, unknown>);
    } catch (error) {
      throw mapSupabaseError(error);
    }
  }

  async startConversation(_idempotencyKey: string): Promise<ConciergeConversation> {
    throw new AppError(ErrorCodes.featureUnavailable);
  }

  watchMessages(
    _conversationId: string,
    onChange: (messages: ConciergeMessage[]) => void,
  ): Unsubscribe {
    onChange([]);
    return () => {};
  }

  // eslint-disable-next-line require-yield
  async *sendMessage(
    _conversationId: string,
    _text: string,
    _idempotencyKey: string,
  ): AsyncGenerator<string> {
    throw new AppError(ErrorCodes.featureUnavailable);
  }
}
