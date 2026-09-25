// DisputeRepository over Supabase: `open_dispute` freezes the payout and
// starts the SLA server-side; reads are RLS-scoped selects on `disputes`
// with the `requests(currency)` embed (the dispute row carries no currency)
// and evidence paths from `dispute_evidence`. Mirrors
// packages/suskii_data/lib/src/supabase/supabase_dispute_repository.dart.

import { AppError, ErrorCodes } from '@/mocks/errors';
import type { Dispute } from '@/mocks/types';
import type { Unsubscribe } from '@/mocks/repos/base';

import { SupabaseGateway, type Row } from './gateway';
import { disputeFromRow } from './mappers';

const disputeColumns =
  'id, request_id, opened_by, reason_code, description, status, ' +
  'sla_due_at, resolution_key, refund_minor, created_at, ' +
  'requests(currency)';

export class SupabaseDisputeRepository {
  constructor(private readonly gateway: SupabaseGateway) {}

  async getMyDisputes(): Promise<Dispute[]> {
    const rows = await this.gateway.selectList('disputes', disputeColumns, {
      orderBy: 'created_at',
      ascending: false,
    });
    return Promise.all(
      rows.map(async (row) => {
        const id = SupabaseGateway.asId(row['id']);
        return disputeFromRow(row, await this.evidencePaths(id));
      }),
    );
  }

  /** Emits the job's latest dispute (or undefined) immediately, then on
   * every change. Evidence changes alone do not retrigger the watch (same
   * as the Dart impl, which streams the disputes table only). */
  watchDispute(
    jobId: string,
    onChange: (dispute: Dispute | undefined) => void,
  ): Unsubscribe {
    let active = true;
    const emit = async (rows: Row[]): Promise<void> => {
      const latest = rows
        .slice()
        .sort((a, b) =>
          String(a['created_at']).localeCompare(String(b['created_at'])),
        )
        .at(-1);
      if (latest === undefined) {
        if (active) onChange(undefined);
        return;
      }
      const id = SupabaseGateway.asId(latest['id']);
      const evidencePaths = await this.evidencePaths(id);
      if (active) onChange(disputeFromRow(latest, evidencePaths));
    };
    const unsubscribe = this.gateway.watchRows(
      'disputes',
      disputeColumns,
      (rows) => void emit(rows),
      {
        column: 'request_id',
        value: jobId,
        filterColumn: 'request_id',
        filterValue: jobId,
      },
    );
    return () => {
      active = false;
      unsubscribe();
    };
  }

  async openDispute(options: {
    jobId: string;
    reasonKey: string;
    idempotencyKey: string;
    details?: string;
    evidencePaths?: string[];
  }): Promise<Dispute> {
    const id = await this.gateway.rpc('open_dispute', {
      p_idempotency_key: options.idempotencyKey,
      p_request_id: options.jobId,
      p_reason_code: options.reasonKey,
      p_description: options.details,
    });
    const disputeId = SupabaseGateway.asId(id);
    // Evidence uploads are separate rows (submit_dispute_evidence) — attach
    // any paths the caller already has.
    for (const path of options.evidencePaths ?? []) {
      await this.gateway.rpc('submit_dispute_evidence', {
        p_idempotency_key: `${options.idempotencyKey}:evidence:${path}`,
        p_dispute_id: disputeId,
        p_kind: 'photo',
        p_storage_path: path,
      });
    }
    const row = await this.gateway.selectSingle(
      'disputes',
      disputeColumns,
      'id',
      disputeId,
    );
    if (row === null) throw new AppError(ErrorCodes.unknown);
    return disputeFromRow(row, await this.evidencePaths(disputeId));
  }

  private async evidencePaths(disputeId: string): Promise<string[]> {
    const rows = await this.gateway.selectList('dispute_evidence', 'storage_path', {
      column: 'dispute_id',
      value: disputeId,
      orderBy: 'created_at',
    });
    return rows
      .map((row) => row['storage_path'] as string | null)
      .filter((p): p is string => p !== null);
  }
}
