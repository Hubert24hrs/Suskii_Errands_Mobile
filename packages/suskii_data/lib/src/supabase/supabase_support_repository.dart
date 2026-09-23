import 'package:suskii_domain/suskii_domain.dart';

import 'supabase_gateway.dart';
import 'supabase_mappers.dart';

/// SupportRepository over Supabase: `open_ticket` / `reply_to_ticket` RPCs
/// for writes; reads are RLS-scoped selects on `support_tickets` with
/// messages batch-fetched from `ticket_messages` and grouped client-side
/// (avoids an N+1 per ticket). The wire has no subject — the category plays
/// that role. AI triage is stored per ticket (`ai_triage` jsonb), not per
/// message, so [SupportMessage.aiTriage] stays false.
class SupabaseSupportRepository implements SupportRepository {
  SupabaseSupportRepository(this._gateway);

  final SupabaseGateway _gateway;

  static const String _ticketColumns =
      'id, request_id, category, status, created_at';
  static const String _messageColumns =
      'id, ticket_id, author_id, body, created_at';

  @override
  Future<List<SupportTicket>> getTickets() async {
    final rows = await _gateway.selectList(
      'support_tickets',
      _ticketColumns,
      orderBy: 'created_at',
      ascending: false,
    );
    return _withMessages(rows);
  }

  @override
  Stream<List<SupportTicket>> watchTickets() => _gateway
      .streamRows('support_tickets', primaryKey: <String>['id'])
      .asyncMap((rows) async {
        rows.sort(
          (a, b) =>
              (b['created_at'] as String).compareTo(a['created_at'] as String),
        );
        return _withMessages(rows);
      });

  @override
  Future<SupportTicket> createTicket({
    required String subject,
    required String body,
    required String idempotencyKey,
  }) async {
    final id = await _gateway.rpc('open_ticket', <String, Object?>{
      'p_idempotency_key': idempotencyKey,
      'p_category': subject,
      'p_body': body,
    });
    final row = await _gateway.selectSingle(
      'support_tickets',
      _ticketColumns,
      column: 'id',
      value: SupabaseGateway.asId(id),
    );
    if (row == null) throw StateError('open_ticket returned no row');
    return supportTicketFromRow(
      row,
      messages: await _messagesFor(<String>[SupabaseGateway.asId(row['id'])]),
    );
  }

  @override
  Future<SupportTicket> replyToTicket(
    String ticketId,
    String body, {
    required String idempotencyKey,
  }) async {
    await _gateway.rpc('reply_to_ticket', <String, Object?>{
      'p_idempotency_key': idempotencyKey,
      'p_ticket_id': ticketId,
      'p_body': body,
    });
    final row = await _gateway.selectSingle(
      'support_tickets',
      _ticketColumns,
      column: 'id',
      value: ticketId,
    );
    if (row == null) throw StateError('ticket vanished after reply');
    return supportTicketFromRow(
      row,
      messages: await _messagesFor(<String>[ticketId]),
    );
  }

  Future<List<SupportTicket>> _withMessages(
    List<Map<String, dynamic>> rows,
  ) async {
    final ids = rows.map((r) => SupabaseGateway.asId(r['id'])).toList();
    final byTicket = await _messagesByTicket(ids);
    return rows
        .map(
          (row) => supportTicketFromRow(
            row,
            messages:
                byTicket[SupabaseGateway.asId(row['id'])] ??
                const <SupportMessage>[],
          ),
        )
        .toList();
  }

  Future<Map<String, List<SupportMessage>>> _messagesByTicket(
    List<String> ticketIds,
  ) async {
    if (ticketIds.isEmpty) return const <String, List<SupportMessage>>{};
    final myId = _gateway.currentAuthUserId ?? '';
    final rows = await _gateway.selectList(
      'ticket_messages',
      _messageColumns,
      inColumn: 'ticket_id',
      inValues: ticketIds,
      orderBy: 'created_at',
    );
    final grouped = <String, List<SupportMessage>>{};
    for (final row in rows) {
      grouped
          .putIfAbsent(
            SupabaseGateway.asId(row['ticket_id']),
            () => <SupportMessage>[],
          )
          .add(supportMessageFromRow(row, myId: myId));
    }
    return grouped;
  }

  Future<List<SupportMessage>> _messagesFor(List<String> ticketIds) async =>
      (await _messagesByTicket(ticketIds))[ticketIds.first] ??
      const <SupportMessage>[];
}
