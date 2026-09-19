import 'package:freezed_annotation/freezed_annotation.dart';

import '../enums.dart';

part 'support.freezed.dart';
part 'support.g.dart';

/// One message in a support ticket thread. AI first-line triage replies have
/// [aiTriage] set so the UI can label them honestly.
@freezed
abstract class SupportMessage with _$SupportMessage {
  const factory SupportMessage({
    required String id,
    required String body,
    required bool fromUser,
    required DateTime createdAt,
    @Default(false) bool aiTriage,
  }) = _SupportMessage;

  factory SupportMessage.fromJson(Map<String, dynamic> json) =>
      _$SupportMessageFromJson(json);
}

/// Help-center ticket (spec: added_features — AI first-line triage with
/// human handoff).
@freezed
abstract class SupportTicket with _$SupportTicket {
  const factory SupportTicket({
    required String id,
    required String subject,
    required SupportTicketStatus status,
    required DateTime createdAt,
    required List<SupportMessage> messages,
  }) = _SupportTicket;

  factory SupportTicket.fromJson(Map<String, dynamic> json) =>
      _$SupportTicketFromJson(json);
}
