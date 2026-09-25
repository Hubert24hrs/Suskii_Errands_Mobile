// OfferRepository over Supabase: negotiation mutations go through the
// contract RPCs (rounds, turn-taking and expiry are server-enforced); reads
// are RLS-scoped selects on `offers` joined with a `get_provider_card`
// lookup per provider for the display fields the offers table does not
// denormalize. Mirrors
// packages/suskii_data/lib/src/supabase/supabase_offer_repository.dart.

import { AppError, ErrorCodes } from '@/mocks/errors';
import type { Money, Offer, RankedOffer } from '@/mocks/types';
import type { Unsubscribe } from '@/mocks/repos/base';

import { SupabaseGateway, type Row } from './gateway';
import { offerFromRow, rankedOfferFromRow } from './mappers';

const offerColumns =
  'id, thread_id, request_id, provider_id, author_side, amount_minor, ' +
  'currency, message, status, round, expires_at, created_at';

export class SupabaseOfferRepository {
  constructor(private readonly gateway: SupabaseGateway) {}

  /** provider id → get_provider_card row, cached for the session (ratings and
   * trust levels drift slowly; offers arrive faster than cards change). */
  private readonly providerCards = new Map<string, Row | null>();

  /** Emits the offer list (oldest first) immediately, then on every change. */
  watchOffers(requestId: string, onChange: (offers: Offer[]) => void): Unsubscribe {
    let active = true;
    const unsubscribe = this.gateway.watchRows(
      'offers',
      offerColumns,
      (rows) => {
        void this.mapOffers(rows)
          .then((offers) => {
            if (active) onChange(offers);
          })
          .catch(() => {
            // Keep the subscription; the next event retries the fetch.
          });
      },
      {
        column: 'request_id',
        value: requestId,
        filterColumn: 'request_id',
        filterValue: requestId,
      },
    );
    return () => {
      active = false;
      unsubscribe();
    };
  }

  private async mapOffers(rows: Row[]): Promise<Offer[]> {
    const offers: Offer[] = [];
    for (const row of rows) {
      offers.push(
        offerFromRow(
          row,
          await this.providerCard(SupabaseGateway.asId(row['provider_id'])),
        ),
      );
    }
    offers.sort((a, b) => a.createdAt.getTime() - b.createdAt.getTime());
    return offers;
  }

  /**
   * The server-side comparison of the live offers on the caller's own
   * request (`rank_offers`). The RPC's row order IS the ranking — callers
   * must not re-sort. ERR_REQUEST_NOT_FOUND means the request is not the
   * caller's own. The wire carries no distance/eta/payout fields, so the
   * Offer entity's optional display fields stay undefined.
   */
  async getRankedOffers(requestId: string): Promise<RankedOffer[]> {
    const rows = (await this.gateway.rpc('rank_offers', {
      p_request_id: requestId,
    })) as Row[];
    return rows.map(rankedOfferFromRow);
  }

  async acceptOffer(offerId: string, idempotencyKey: string): Promise<Offer> {
    return this.mutate('accept_offer', offerId, {
      p_idempotency_key: idempotencyKey,
    });
  }

  async declineOffer(offerId: string, idempotencyKey: string): Promise<Offer> {
    return this.mutate('decline_offer', offerId, {
      p_idempotency_key: idempotencyKey,
    });
  }

  async withdrawOffer(offerId: string, idempotencyKey: string): Promise<Offer> {
    return this.mutate('withdraw_offer', offerId, {
      p_idempotency_key: idempotencyKey,
    });
  }

  async counterOffer(options: {
    offerId: string;
    amount: Money;
    idempotencyKey: string;
    message?: string;
  }): Promise<Offer> {
    // counter_offer returns the NEW offer's uuid (the countered offer row
    // keeps its own id), so this re-selects that row instead.
    const newId = await this.gateway.rpc('counter_offer', {
      p_idempotency_key: options.idempotencyKey,
      p_offer_id: options.offerId,
      p_amount_minor: options.amount.amountMinor,
      p_message: options.message,
    });
    return this.loadOffer(SupabaseGateway.asId(newId));
  }

  /** The status-mutation RPCs return scalars; the entity needs the full row,
   * so every mutation re-selects. */
  private async mutate(
    fn: string,
    offerId: string,
    args: Record<string, unknown>,
  ): Promise<Offer> {
    await this.gateway.rpc(fn, { p_offer_id: offerId, ...args });
    return this.loadOffer(offerId);
  }

  private async loadOffer(offerId: string): Promise<Offer> {
    const row = await this.gateway.selectSingle('offers', offerColumns, 'id', offerId);
    if (row === null) throw new AppError(ErrorCodes.unknown);
    return offerFromRow(
      row,
      await this.providerCard(SupabaseGateway.asId(row['provider_id'])),
    );
  }

  private async providerCard(providerId: string): Promise<Row | null> {
    if (this.providerCards.has(providerId)) {
      return this.providerCards.get(providerId) ?? null;
    }
    const rows = (await this.gateway.rpc('get_provider_card', {
      p_provider_id: providerId,
    })) as Row[];
    const card = rows.length === 0 ? null : rows[0];
    this.providerCards.set(providerId, card);
    return card;
  }
}
