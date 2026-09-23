import 'package:suskii_domain/suskii_domain.dart';

import 'supabase_gateway.dart';
import 'supabase_mappers.dart';

/// ChatRepository over Supabase: `send_message` (idempotent, moderation and
/// chat-window rules server-side); reads stream the `messages` table scoped
/// to the job's conversation. Read receipts derive from the other
/// participant's `message_reads` pointer (the wire has no per-message read
/// timestamp).
class SupabaseChatRepository implements ChatRepository {
  SupabaseChatRepository(this._gateway);

  final SupabaseGateway _gateway;

  static const String _columns =
      'id, conversation_id, sender_id, type, body, media_path, offer_id, '
      'location, created_at, conversations(request_id)';

  @override
  Stream<List<ChatMessage>> watchMessages(String jobId) async* {
    final conversation = await _conversationId(jobId);
    if (conversation == null) {
      yield const <ChatMessage>[];
      return;
    }
    await for (final rows in _gateway.streamRows(
      'messages',
      primaryKey: <String>['id'],
      filterColumn: 'conversation_id',
      filterValue: conversation,
    )) {
      final read = await _otherReadPointer(conversation);
      final messages = <ChatMessage>[
        for (final row in rows)
          chatMessageFromRow(row, jobId: jobId, readAt: _readAtFor(row, read)),
      ]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      yield List<ChatMessage>.unmodifiable(messages);
    }
  }

  @override
  Future<ChatMessage> sendMessage({
    required String jobId,
    required ChatMessageType type,
    required String idempotencyKey,
    String? text,
    String? mediaPath,
    GeoPoint? location,
  }) async {
    // Returns the new message's id (bigint — opaque string on the entity).
    final id = await _gateway.rpc('send_message', <String, Object?>{
      'p_idempotency_key': idempotencyKey,
      'p_request_id': jobId,
      'p_body': text,
      'p_type': chatMessageTypeToWire(type),
      'p_media_path': mediaPath,
      'p_lat': location?.latitude,
      'p_lng': location?.longitude,
    });
    final rows = await _gateway.selectList(
      'messages',
      _columns,
      column: 'id',
      value: SupabaseGateway.asId(id),
    );
    return chatMessageFromRow(rows.first, jobId: jobId);
  }

  Future<String?> _conversationId(String jobId) async {
    final row = await _gateway.selectSingle(
      'conversations',
      'id',
      column: 'request_id',
      value: jobId,
    );
    return row == null ? null : SupabaseGateway.asId(row['id']);
  }

  /// The other participant's (last_read_message_id, read_at), or null.
  Future<(int, DateTime)?> _otherReadPointer(String conversationId) async {
    final rows = await _gateway.selectList(
      'message_reads',
      'user_id, last_read_message_id, read_at',
      column: 'conversation_id',
      value: conversationId,
    );
    final myId = _gateway.currentAuthUserId;
    for (final row in rows) {
      if (row['user_id'] != myId) {
        return (
          SupabaseGateway.asMinorUnits(row['last_read_message_id']),
          SupabaseGateway.asTimestamp(row['read_at']),
        );
      }
    }
    return null;
  }

  /// A message reads as read when the other participant's pointer has passed
  /// it; the pointer's read_at stands in for a per-message timestamp.
  DateTime? _readAtFor(Map<String, dynamic> row, (int, DateTime)? pointer) {
    if (pointer == null) return null;
    final (lastRead, readAt) = pointer;
    return SupabaseGateway.asMinorUnits(row['id']) <= lastRead ? readAt : null;
  }
}
