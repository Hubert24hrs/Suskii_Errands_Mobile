import 'package:freezed_annotation/freezed_annotation.dart';

part 'settings.freezed.dart';
part 'settings.g.dart';

/// Per-channel notification preferences with quiet hours (spec:
/// communication.notifications — transactional vs marketing split).
@freezed
abstract class NotificationPreferences with _$NotificationPreferences {
  const factory NotificationPreferences({
    required bool push,
    required bool sms,
    required bool email,

    /// Marketing messages only; transactional alerts always go through.
    required bool marketing,

    /// Quiet hours as minutes since midnight, local time. Null = off.
    int? quietStartMinutes,
    int? quietEndMinutes,
  }) = _NotificationPreferences;

  factory NotificationPreferences.fromJson(Map<String, dynamic> json) =>
      _$NotificationPreferencesFromJson(json);
}

/// A trusted contact (up to 5 per user) — notified on SOS and eligible for
/// live-trip share links (spec: safety.trusted_contacts).
@freezed
abstract class TrustedContact with _$TrustedContact {
  const factory TrustedContact({
    required String id,
    required String name,
    required String phoneE164,
  }) = _TrustedContact;

  factory TrustedContact.fromJson(Map<String, dynamic> json) =>
      _$TrustedContactFromJson(json);
}
