// PaymentRepository over Supabase: `start_payment` creates the attempt
// server-side (status flips arrive via webhook + server-side verify — the
// client only watches); `get_payment_checkout` supplies the gateway page for
// card/mobile-money completion. Mirrors
// packages/suskii_data/lib/src/supabase/supabase_payment_repository.dart.

import { AppError, ErrorCodes } from '@/mocks/errors';
import type { Payment, PaymentMethod, PaymentSession } from '@/mocks/types';
import type { Unsubscribe } from '@/mocks/repos/base';

import { SupabaseGateway, type Row } from './gateway';
import { paymentFromRow, paymentMethodToWire } from './mappers';

/** Column grants on payments deliberately exclude `checkout_url` — the
 * checkout page only ever comes from `get_payment_checkout`. */
const paymentColumns =
  'id, request_id, payer_id, gateway, gateway_reference, method, ' +
  'amount_minor, currency, status, expires_at, confirmed_at, ' +
  'failed_reason_key, created_at';

/** A job can have several attempts (failed retries); the latest is the one
 * that matters. */
function latest(rows: Row[]): Row | undefined {
  return rows
    .slice()
    .sort((a, b) =>
      String(a['created_at']).localeCompare(String(b['created_at'])),
    )
    .at(-1);
}

export class SupabasePaymentRepository {
  constructor(private readonly gateway: SupabaseGateway) {}

  async getPaymentForJob(jobId: string): Promise<Payment | undefined> {
    const rows = await this.gateway.selectList('payments', paymentColumns, {
      column: 'request_id',
      value: jobId,
      orderBy: 'created_at',
      ascending: false,
      limit: 1,
    });
    return rows.length === 0 ? undefined : paymentFromRow(rows[0]);
  }

  /** Emits the latest payment (or undefined) immediately, then changes. */
  watchPaymentForJob(
    jobId: string,
    onChange: (payment: Payment | undefined) => void,
  ): Unsubscribe {
    return this.gateway.watchRows(
      'payments',
      paymentColumns,
      (rows) => {
        const row = latest(rows);
        onChange(row === undefined ? undefined : paymentFromRow(row));
      },
      {
        column: 'request_id',
        value: jobId,
        filterColumn: 'request_id',
        filterValue: jobId,
      },
    );
  }

  async initializePayment(options: {
    jobId: string;
    method: PaymentMethod;
    idempotencyKey: string;
  }): Promise<PaymentSession> {
    const rows = (await this.gateway.rpc('start_payment', {
      p_idempotency_key: options.idempotencyKey,
      p_request_id: options.jobId,
      p_method: paymentMethodToWire(options.method),
    })) as Row[];
    const paymentId = SupabaseGateway.asId(rows[0]['payment_id']);
    const paymentRow = await this.gateway.selectSingle(
      'payments',
      paymentColumns,
      'id',
      paymentId,
    );
    if (paymentRow === null) {
      // The RPC created the attempt; an unreadable row is a server problem.
      throw new AppError(ErrorCodes.unknown);
    }
    // Card/mobile-money complete on the gateway's own page; the checkout URL
    // is an RPC read, not a table column (see the grants note above). USSD /
    // bank-transfer instructions are not in the contract yet — tracked as
    // CR-20260923-02; those session fields stay undefined until then.
    let checkoutUrl: string | undefined;
    if (options.method === 'card' || options.method === 'mobile_money') {
      const checkout = (await this.gateway.rpc('get_payment_checkout', {
        p_request_id: options.jobId,
      })) as Row[];
      if (checkout.length > 0) {
        checkoutUrl = (checkout[0]['checkout_url'] as string | null) ?? undefined;
      }
    }
    return { payment: paymentFromRow(paymentRow), checkoutUrl };
  }
}
