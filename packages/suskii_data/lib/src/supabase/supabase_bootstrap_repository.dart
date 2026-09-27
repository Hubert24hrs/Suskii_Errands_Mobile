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
  Future<AppBootstrap> getBootstrap({String? countryCode}) async {
    var payload = await _fetch(countryCode);
    var packMap = payload['country_pack'] as Map<String, dynamic>?;
    if (packMap == null) {
      // A first run has no profile and may have no choice yet: the country
      // picker needs a bootstrap to list the countries, so fall back to the
      // first open one rather than failing before the user can choose
      // (audit 2026-09-27 Y.26). Only a country list with nothing open is an
      // error.
      final countries = (payload['countries'] as List<dynamic>? ?? const [])
          .cast<Map<String, dynamic>>();
      final fallback = countries
          .where((c) => c['status'] == 'live')
          .followedBy(countries)
          .map((c) => c['code'] as String?)
          .whereType<String>()
          .firstOrNull;
      if (fallback == null || fallback == countryCode) {
        throw const AppError(ErrorCodes.countryDisabled);
      }
      payload = await _fetch(fallback);
      packMap = payload['country_pack'] as Map<String, dynamic>?;
      if (packMap == null) throw const AppError(ErrorCodes.countryDisabled);
    }
    final config =
        payload['remote_config'] as Map<String, dynamic>? ?? const {};
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
      accountDeletionScheduledFor: userMap?['deletion_scheduled_for'] == null
          ? null
          : SupabaseGateway.asTimestamp(userMap!['deletion_scheduled_for']),
      // No server source yet without an N+1 over requests — tracked in
      // HANDOFF as an M9 follow-up (candidate change request: an
      // active_job_banner field in get_bootstrap), so the banner is absent.
    );
  }

  Future<Map<String, dynamic>> _fetch(String? countryCode) async {
    final raw = await _gateway.rpc('get_bootstrap', <String, Object?>{
      'p_country_code': countryCode?.toUpperCase(),
    });
    return raw as Map<String, dynamic>;
  }

  @override
  Stream<AppNotification> watchNotifications() => _gateway
      .streamRows('notifications', primaryKey: const <String>['id'])
      .asyncExpand(
        (rows) => Stream.fromIterable(rows.map(appNotificationFromRow)),
      );
}
