// ChatRepository over Supabase: `send_message` (idempotent — moderation and
// the chat-window rules stay server-side, ERR_CHAT_CLOSED surfaces as an
// error as on the mock); reads stream the `messages` table scoped to the
// job's conversation. Read receipts derive from the OTHER participant's
// `message_reads` pointer (the wire has no per-message read timestamp — a
// message counts as read once the pointer has passed it, and renders the
// pointer's read_at). Mirrors
// packages/suskii_data/lib/src/supabase/supabase_chat_repository.dart.

import type { ChatMessage, ChatMessageType, GeoPoint } from '@/mocks/types';
import type { Unsubscribe } from '@/mocks/repos/base';

import { SupabaseGateway, type Row } from './gateway';
import {
  chatMessageFromRow,
  chatMessageTypeToWire,
  messageIdAtMost,
} from './mappers';

/** Explicit columns; `moderation_status`/`moderation_flags` are deliberately
 * not read (moderation outcomes surface as send errors, not row state). */
const messageColumns =
  'id, conversation_id, sender_id, type, body, media_path, offer_id, ' +
  'location, created_at, conversations(request_id)';

interface ReadPointer {
  lastRead: unknown;
  readAt: Date;
}

export class SupabaseChatRepository {
  constructor(private readonly gateway: SupabaseGateway) {}

  /** Emits the full message list (oldest first) immediately, then on every
   * change. A job with no conversation yet emits an empty list and does not
   * re-watch (same as the Dart impl). */
  watchMessages(
    jobId: string,
    onChange: (messages: ChatMessage[]) => void,
  ): Unsubscribe {
    let active = true;
    let unsubscribe: Unsubscribe = () => undefined;
    void (async () => {
      const conversationId = await this.conversationId(jobId);
      if (!active) return;
      if (conversationId === null) {
        onChange([]);
        return;
      }
      const emit = async (rows: Row[]): Promise<void> => {
        const read = await this.otherReadPointer(conversationId);
        const messages = rows
          .map((row) =>
            chatMessageFromRow(row, { jobId, readAt: readAtFor(row, read) }),
          )
          .sort((a, b) => a.createdAt.getTime() - b.createdAt.getTime());
        if (active) onChange(messages);
      };
      unsubscribe = this.gateway.watchRows(
        'messages',
        messageColumns,
        (rows) => void emit(rows),
        {
          column: 'conversation_id',
          value: conversationId,
          filterColumn: 'conversation_id',
          filterValue: conversationId,
        },
      );
    })();
    return () => {
      active = false;
      unsubscribe();
    };
  }

  async sendMessage(options: {
    jobId: string;
    type: ChatMessageType;
    idempotencyKey: string;
    text?: string;
    mediaPath?: string;
    location?: GeoPoint;
    offerId?: string;
  }): Promise<ChatMessage> {
    // Returns the new message's id (bigint — opaque string on the entity).
    // The web interface carries offerId for offer_card messages; the
    // contract's p_offer_id takes it (the Dart repo omits it — mobile never
    // sends offer cards from chat).
    const id = await this.gateway.rpc('send_message', {
      p_idempotency_key: options.idempotencyKey,
      p_request_id: options.jobId,
      p_body: options.text,
      p_type: chatMessageTypeToWire(options.type),
      p_media_path: options.mediaPath,
      p_offer_id: options.offerId,
      p_lat: options.location?.latitude,
      p_lng: options.location?.longitude,
    });
    const rows = await this.gateway.selectList('messages', messageColumns, {
      column: 'id',
      value: SupabaseGateway.asId(id),
    });
    return chatMessageFromRow(rows[0], { jobId: options.jobId });
  }

  /** Web-only method (the Dart interface has no counterpart): advances the
   * caller's read pointer to the latest message via `mark_read`. The RPC
   * takes no idempotency key — advancing the pointer to the same maximum is
   * naturally idempotent, so the interface's key is unused. */
  async markMessagesRead(jobId: string, _idempotencyKey: string): Promise<void> {
    const conversationId = await this.conversationId(jobId);
    if (conversationId === null) return;
    const rows = await this.gateway.selectList('messages', 'id', {
      column: 'conversation_id',
      value: conversationId,
      orderBy: 'id',
      ascending: false,
      limit: 1,
    });
    if (rows.length === 0) return;
    await this.gateway.rpc('mark_read', {
      p_request_id: jobId,
      p_last_message_id: SupabaseGateway.asMinorUnits(rows[0]['id']),
    });
  }

  private async conversationId(jobId: string): Promise<string | null> {
    const row = await this.gateway.selectSingle(
      'conversations',
      'id',
      'request_id',
      jobId,
    );
    return row === null ? null : SupabaseGateway.asId(row['id']);
  }

  /** The other participant's (last_read_message_id, read_at), or undefined. */
  private async otherReadPointer(
    conversationId: string,
  ): Promise<ReadPointer | undefined> {
    const rows = await this.gateway.selectList(
      'message_reads',
      'user_id, last_read_message_id, read_at',
      { column: 'conversation_id', value: conversationId },
    );
    const myId = await this.gateway.currentAuthUserId();
    for (const row of rows) {
      if (row['user_id'] !== myId) {
        return {
          lastRead: row['last_read_message_id'],
          readAt: SupabaseGateway.asTimestamp(row['read_at']),
        };
      }
    }
    return undefined;
  }
}

/** A message reads as read when the other participant's pointer has passed
 * it; the pointer's read_at stands in for a per-message timestamp. */
function readAtFor(row: Row, pointer: ReadPointer | undefined): Date | undefined {
  if (pointer === undefined || row['id'] == null || pointer.lastRead == null) {
    return undefined;
  }
  return messageIdAtMost(row['id'], pointer.lastRead)
    ? pointer.readAt
    : undefined;
}
