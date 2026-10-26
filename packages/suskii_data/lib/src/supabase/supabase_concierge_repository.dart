import 'dart:async';

import 'package:suskii_domain/suskii_domain.dart';

import 'supabase_gateway.dart';
import 'supabase_mappers.dart';

/// Ask Suskii over Supabase (ADR-0024). `concierge_start` opens the
/// conversation (refused with ERR_FEATURE_UNAVAILABLE when `concierge.text` is
/// off); each message is one call to the `concierge` Edge Function; the
/// history is the caller's own `ai_messages`, redacted as stored.
///
/// A turn never fails the screen when the AI cannot help: a switched-off
/// concierge, a limit or a model that is down all come back as a reply with
/// `handoff_to_form`, and the form is always there.
class SupabaseConciergeRepository implements ConciergeRepository {
  SupabaseConciergeRepository(this._gateway);

  final SupabaseGateway _gateway;
  final StreamController<void> _sent = StreamController<void>.broadcast();

  static const String _columns =
      'id, conversation_id, role, body, structured_draft, proposed_action, '
      'created_at';

  @override
  Future<ConciergeConversation> startConversation({
    required String idempotencyKey,
  }) async {
    final rows = await _gateway.rpc('concierge_start', <String, Object?>{
      'p_idempotency_key': idempotencyKey,
    });
    final row = Map<String, dynamic>.from((rows as List<dynamic>).first as Map);
    return ConciergeConversation(
      id: SupabaseGateway.asId(row['id']),
      createdAt: SupabaseGateway.asTimestamp(row['created_at']),
      language: row['language'] as String?,
    );
  }

  @override
  Stream<List<ConciergeMessage>> watchMessages(String conversationId) {
    final userId = _gateway.currentAuthUserId;
    return _gateway
        .streamRows(
          'ai_messages',
          columns: _columns,
          filterColumn: 'conversation_id',
          filterValue: conversationId,
          // `concierge.turn` on the caller's own topic says a turn was written.
          topics: <String>[if (userId != null) 'user:$userId'],
          every: const Duration(seconds: 20),
          nudges: _sent.stream,
        )
        .map((rows) {
          final messages = <ConciergeMessage>[
            for (final row in rows) conciergeMessageFromRow(row),
          ]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
          return List<ConciergeMessage>.unmodifiable(messages);
        });
  }

  @override
  Stream<String> sendMessage(
    String conversationId,
    String text, {
    required String idempotencyKey,
  }) async* {
    final answer = await _gateway.invokeFunction('concierge', <String, Object?>{
      'conversation_id': conversationId,
      'text': text,
      'idempotency_key': idempotencyKey,
    });
    // The reply is written before the function answers; read it now rather
    // than at the next broadcast or tick.
    _sent.add(null);
    final reply = answer['reply'];
    if (reply is String && reply.isNotEmpty) yield reply;
  }
}
