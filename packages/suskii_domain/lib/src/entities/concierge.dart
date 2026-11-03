import 'package:freezed_annotation/freezed_annotation.dart';

import '../enums.dart';
import '../money.dart';
import 'request.dart';

part 'concierge.freezed.dart';
part 'concierge.g.dart';

@freezed
abstract class ConciergeConversation with _$ConciergeConversation {
  const factory ConciergeConversation({
    required String id,
    required DateTime createdAt,
    String? language,
  }) = _ConciergeConversation;

  factory ConciergeConversation.fromJson(Map<String, dynamic> json) =>
      _$ConciergeConversationFromJson(json);
}

@freezed
abstract class ConciergeMessage with _$ConciergeMessage {
  const factory ConciergeMessage({
    required String id,
    required String conversationId,
    required ConciergeRole role,
    required String text,
    required DateTime createdAt,

    /// The slot-filled request as the assistant currently understands it.
    /// Present on assistant messages once structuring has started.
    ConciergeDraft? structuredDraft,

    /// What the assistant proposes the UI do next (render a publish card,
    /// hand off to the form, ...). `none` on plain conversation turns.
    @Default(ConciergeProposedAction.none)
    ConciergeProposedAction proposedAction,
  }) = _ConciergeMessage;

  factory ConciergeMessage.fromJson(Map<String, dynamic> json) =>
      _$ConciergeMessageFromJson(json);
}

/// The request the concierge has structured so far. Server-side slot filling;
/// the UI renders the draft and asks for confirmation before publishing.
/// The server creates the underlying draft [JobRequest] from the first saved
/// slot and sets [requestId]; the publish card then calls
/// `RequestRepository.publishRequest(requestId, idempotencyKey)` — the
/// concierge itself holds no publish capability (review M3.1).
@freezed
abstract class ConciergeDraft with _$ConciergeDraft {
  const factory ConciergeDraft({
    required bool isCustomCategory,
    required List<String> missingSlots,

    /// The server-side draft [JobRequest] backing this structured draft.
    /// Set from the first saved slot so a half-finished concierge draft is
    /// resumable; the publish card calls
    /// `RequestRepository.publishRequest(requestId, …)` once all slots are in.
    String? requestId,
    String? categoryId,
    String? description,
    PlaceRef? pickup,
    PlaceRef? destination,
    Urgency? urgency,
    DateTime? scheduledAt,
    Money? preferredPrice,
    Money? itemFloat,
    Money? declaredValue,
  }) = _ConciergeDraft;

  factory ConciergeDraft.fromJson(Map<String, dynamic> json) =>
      _$ConciergeDraftFromJson(json);
}

/// Ask Suskii allowance for the signed-in person (`my_ai_usage()`,
/// 20261103120200). Counted and enforced on the server; the app only shows it.
@freezed
abstract class AiUsage with _$AiUsage {
  const factory AiUsage({
    required int dailyLimit,
    required int usedToday,
    required int remainingToday,
    required int monthlyLimit,
    required int usedThisMonth,
    required int remainingThisMonth,
    required DateTime dayResetsAt,
    required DateTime monthResetsAt,
    @Default(0) int credits,
    DateTime? suspendedUntil,

    /// False when Ask Suskii is switched off or the platform's AI budget is
    /// spent: say it is unavailable, not that the person is over a limit.
    @Default(true) bool available,
  }) = _AiUsage;

  factory AiUsage.fromJson(Map<String, dynamic> json) =>
      _$AiUsageFromJson(json);
}
