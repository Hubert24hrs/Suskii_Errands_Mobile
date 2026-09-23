import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_domain/suskii_domain.dart';

import 'supabase_gateway.dart';
import 'supabase_mappers.dart';

/// SettingsRepository over Supabase.
///
/// Notification preferences live in `notification_preferences` (one row per
/// channel × category); the flat domain model is composed/exploded by
/// [notificationPreferencesFromRows] / [notificationPreferenceRows] and
/// written with an upsert on the (user_id, channel, category) key.
///
/// Trusted contacts: the contract stores phone numbers encrypted
/// (`phone_ciphertext` + blind index) and offers no client key-management or
/// server-side encrypt helper, so [addTrustedContact] is unavailable until
/// CR-20260923-06 lands; reads map with an empty `phoneE164`.
///
/// Account deletion / data export have no RPCs yet (CR-20260923-07).
class SupabaseSettingsRepository implements SettingsRepository {
  SupabaseSettingsRepository(this._gateway);

  final SupabaseGateway _gateway;

  static const String _prefColumns =
      'channel, category, enabled, quiet_start, quiet_end';
  static const String _contactColumns = 'id, name, created_at';

  @override
  Future<NotificationPreferences> getNotificationPreferences() async {
    final rows = await _gateway.selectList(
      'notification_preferences',
      _prefColumns,
    );
    return notificationPreferencesFromRows(rows);
  }

  @override
  Future<NotificationPreferences> updateNotificationPreferences(
    NotificationPreferences preferences, {
    required String idempotencyKey,
  }) async {
    final userId = _gateway.currentAuthUserId;
    if (userId == null) throw const AppError(ErrorCodes.unauthenticated);
    final rows = await _gateway.upsertRows(
      'notification_preferences',
      notificationPreferenceRows(userId, preferences),
      onConflict: 'user_id,channel,category',
      columns: _prefColumns,
    );
    return notificationPreferencesFromRows(rows);
  }

  @override
  Future<List<TrustedContact>> getTrustedContacts() async {
    final rows = await _gateway.selectList(
      'trusted_contacts',
      _contactColumns,
      orderBy: 'created_at',
    );
    return rows.map(trustedContactFromRow).toList();
  }

  @override
  Future<TrustedContact> addTrustedContact({
    required String name,
    required String phoneE164,
    required String idempotencyKey,
  }) async =>
      // add_trusted_contact expects phone_ciphertext + blind index; the
      // client has no encryption story (CR-20260923-06) and sending
      // plaintext as "ciphertext" would weaken the security model.
      throw const AppError(ErrorCodes.featureUnavailable);

  @override
  Future<void> removeTrustedContact(
    String contactId, {
    required String idempotencyKey,
  }) async {
    await _gateway.rpc('remove_trusted_contact', <String, Object?>{
      'p_contact_id': contactId,
    });
  }

  @override
  Future<DateTime> requestAccountDeletion({
    required String idempotencyKey,
  }) async =>
      // No account-deletion RPC in contracts v1 (CR-20260923-07).
      throw const AppError(ErrorCodes.featureUnavailable);

  @override
  Future<String> requestDataExport({required String idempotencyKey}) async =>
      // No data-export RPC in contracts v1 (CR-20260923-07).
      throw const AppError(ErrorCodes.featureUnavailable);
}
