// SupportRepository over Supabase: `open_ticket` / `reply_to_ticket` RPCs
// for writes; reads are RLS-scoped selects on `support_tickets` with
// messages batch-fetched from `ticket_messages` and grouped client-side
// (avoids an N+1 per ticket). The wire has no subject — the category plays
// that role. AI triage is stored per ticket (`ai_triage` jsonb), not per
// message, so SupportMessage.aiTriage stays false. Mirrors
// packages/suskii_data/lib/src/supabase/supabase_support_repository.dart.

import { AppError, ErrorCodes } from '@/mocks/errors';
import type { SupportMessage, SupportTicket } from '@/mocks/types';
import type { Unsubscribe } from '@/mocks/repos/base';

import { SupabaseGateway, type Row } from './gateway';
import { supportMessageFromRow, supportTicketFromRow } from './mappers';

const ticketColumns = 'id, request_id, category, status, created_at';
const messageColumns = 'id, ticket_id, author_id, body, created_at';

export class SupabaseSupportRepository {
  constructor(private readonly gateway: SupabaseGateway) {}

  async getTickets(): Promise<SupportTicket[]> {
    const rows = await this.gateway.selectList('support_tickets', ticketColumns, {
      orderBy: 'created_at',
      ascending: false,
    });
    return this.withMessages(rows);
  }

  /** Emits the sorted ticket list (newest first) immediately, then on every
   * change. Message inserts alone do not retrigger the watch (same as the
   * Dart impl, which streams the tickets table only). */
  watchTickets(onChange: (tickets: SupportTicket[]) => void): Unsubscribe {
    let active = true;
    const emit = async (rows: Row[]): Promise<void> => {
      const sorted = rows
        .slice()
        .sort((a, b) =>
          String(b['created_at']).localeCompare(String(a['created_at'])),
        );
      const tickets = await this.withMessages(sorted);
      if (active) onChange(tickets);
    };
    const unsubscribe = this.gateway.watchRows(
      'support_tickets',
      ticketColumns,
      (rows) => void emit(rows),
    );
    return () => {
      active = false;
      unsubscribe();
    };
  }

  async createTicket(options: {
    subject: string;
    body: string;
    idempotencyKey: string;
  }): Promise<SupportTicket> {
    const id = await this.gateway.rpc('open_ticket', {
      p_idempotency_key: options.idempotencyKey,
      p_category: options.subject,
      p_body: options.body,
    });
    const ticketId = SupabaseGateway.asId(id);
    const row = await this.gateway.selectSingle(
      'support_tickets',
      ticketColumns,
      'id',
      ticketId,
    );
    if (row === null) throw new AppError(ErrorCodes.unknown);
    return supportTicketFromRow(row, await this.messagesFor(ticketId));
  }

  async replyToTicket(
    ticketId: string,
    body: string,
    idempotencyKey: string,
  ): Promise<SupportTicket> {
    await this.gateway.rpc('reply_to_ticket', {
      p_idempotency_key: idempotencyKey,
      p_ticket_id: ticketId,
      p_body: body,
    });
    const row = await this.gateway.selectSingle(
      'support_tickets',
      ticketColumns,
      'id',
      ticketId,
    );
    if (row === null) throw new AppError(ErrorCodes.unknown);
    return supportTicketFromRow(row, await this.messagesFor(ticketId));
  }

  private async withMessages(rows: Row[]): Promise<SupportTicket[]> {
    const byTicket = await this.messagesByTicket(
      rows.map((r) => SupabaseGateway.asId(r['id'])),
    );
    return rows.map((row) =>
      supportTicketFromRow(
        row,
        byTicket.get(SupabaseGateway.asId(row['id'])) ?? [],
      ),
    );
  }

  private async messagesFor(ticketId: string): Promise<SupportMessage[]> {
    return (await this.messagesByTicket([ticketId])).get(ticketId) ?? [];
  }

  private async messagesByTicket(
    ticketIds: string[],
  ): Promise<Map<string, SupportMessage[]>> {
    const grouped = new Map<string, SupportMessage[]>();
    if (ticketIds.length === 0) return grouped;
    const myId = (await this.gateway.currentAuthUserId()) ?? '';
    const rows = await this.gateway.selectList('ticket_messages', messageColumns, {
      inColumn: 'ticket_id',
      inValues: ticketIds,
      orderBy: 'created_at',
    });
    for (const row of rows) {
      const key = SupabaseGateway.asId(row['ticket_id']);
      const list = grouped.get(key) ?? [];
      list.push(supportMessageFromRow(row, myId));
      grouped.set(key, list);
    }
    return grouped;
  }
}
