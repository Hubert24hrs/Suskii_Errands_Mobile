import 'package:freezed_annotation/freezed_annotation.dart';

import '../enums.dart';
import '../geo_point.dart';

part 'chat.freezed.dart';
part 'chat.g.dart';

@freezed
abstract class ChatMessage with _$ChatMessage {
  const factory ChatMessage({
    required String id,
    required String jobId,
    required String senderId,
    required ChatMessageType type,
    required DateTime createdAt,
    String? text,
    String? mediaPath,
    String? offerId,
    GeoPoint? location,
    DateTime? readAt,
  }) = _ChatMessage;

  factory ChatMessage.fromJson(Map<String, dynamic> json) =>
      _$ChatMessageFromJson(json);
}
