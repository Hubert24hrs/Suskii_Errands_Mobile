import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_domain/suskii_domain.dart';

import 'supabase_gateway.dart';
import 'supabase_mappers.dart';

/// BootstrapRepository over Supabase: cold-start payload from the
/// `get_bootstrap` RPC plus the unread-notification count, and live
/// notifications from the `notifications` table stream (RLS scopes rows to
/// the signed-in user).
class SupabaseBootstrapRepository implements BootstrapRepository {
  SupabaseBootstrapRepository(this._gateway);

  final SupabaseGateway _gateway;

  @override
  Future<AppBootstrap> getBootstrap() async {
    final raw = await _gateway.rpc('get_bootstrap');
    final payload = raw as Map<String, dynamic>;
    final config =
        payload['remote_config'] as Map<String, dynamic>? ?? const {};
    final packMap = payload['country_pack'] as Map<String, dynamic>?;
    if (packMap == null) {
      // No beta/live country for the caller's profile or hint.
      throw const AppError(ErrorCodes.countryDisabled);
    }
    final pack = packMap['code'] as String;
    final cities = await _gateway.selectList(
      'cities',
      'name',
      column: 'country_code',
      value: pack,
    );
    final userMap = payload['user'] as Map<String, dynamic>?;
    return AppBootstrap(
      countryPack: countryPackFromBootstrap(
        packMap,
        launchCities: cities
            .map((row) => row['name'] as String)
            .toList(growable: false),
      ),
      featureFlags:
          (payload['feature_flags'] as Map<String, dynamic>? ?? const {}).map(
            (key, value) => MapEntry(key, value == true),
          ),
      voiceLanguages:
          (config['voice_languages'] as Map<String, dynamic>? ?? const {}).map(
            (key, value) => MapEntry(key, value == true),
          ),
      minSupportedAppVersion:
          payload['min_supported_app_version'] as String? ?? '0.0.0',
      unreadNotifications: await _gateway.countRows(
        'notifications',
        isNullColumn: 'read_at',
      ),
      serverTime: SupabaseGateway.asTimestamp(payload['server_time']),
      user: userMap == null ? null : appUserFromProfileRow(userMap),
      // No server source yet without an N+1 over requests — tracked in
      // HANDOFF as an M9 follow-up (candidate change request: an
      // active_job_banner field in get_bootstrap), so the banner is absent.
    );
  }

  @override
  Stream<AppNotification> watchNotifications() => _gateway
      .streamRows('notifications', primaryKey: const <String>['id'])
      .asyncExpand(
        (rows) => Stream.fromIterable(rows.map(appNotificationFromRow)),
      );
}
