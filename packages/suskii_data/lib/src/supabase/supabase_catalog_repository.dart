import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_domain/suskii_domain.dart';

import 'supabase_gateway.dart';
import 'supabase_mappers.dart';

/// CatalogRepository over Supabase: the service taxonomy (client-readable
/// `service_categories`), the caller's country pack (via `get_bootstrap`,
/// which is anon-callable so the pre-login country picker works), and the
/// server-computed price band.
class SupabaseCatalogRepository implements CatalogRepository {
  SupabaseCatalogRepository(this._gateway);

  final SupabaseGateway _gateway;

  /// Category key → uuid, built lazily from getCategories. The RPCs that take
  /// `category_id` (get_price_band, get_availability_summary,
  /// get_category_requirements) want the uuid; everything else on the wire
  /// takes the key (`create_request`'s `p_category_key`).
  final Map<String, String> _categoryUuids = <String, String>{};

  @override
  Future<List<ServiceCategory>> getCategories() async {
    final rows = await _gateway.selectList(
      'service_categories',
      'id, key, name_key, icon_key, allows_custom, offer_ttl_seconds, '
          'max_counter_rounds, proof_requirements',
      column: 'active',
      value: true,
      orderBy: 'sort_order',
    );
    _categoryUuids
      ..clear()
      ..addEntries(
        rows.map(
          (row) =>
              MapEntry(row['key'] as String, SupabaseGateway.asId(row['id'])),
        ),
      );
    return rows.map(serviceCategoryFromRow).toList(growable: false);
  }

  @override
  Future<CountryPack> getCountryPack(String countryCode) async {
    final bootstrap = await _gateway.rpc('get_bootstrap', <String, Object?>{
      'p_country_code': countryCode,
    });
    final pack =
        (bootstrap as Map<String, dynamic>)['country_pack']
            as Map<String, dynamic>?;
    if (pack == null) {
      // Disabled/unknown country: get_bootstrap returns no pack.
      throw const AppError(ErrorCodes.countryDisabled);
    }
    final cities = await _gateway.selectList(
      'cities',
      'name',
      column: 'country_code',
      value: countryCode,
    );
    return countryPackFromBootstrap(
      pack,
      launchCities: cities
          .map((row) => row['name'] as String)
          .toList(growable: false),
    );
  }

  @override
  Future<PriceBand?> getPriceBand({
    required String categoryId,
    Urgency urgency = Urgency.standard,
    String? cityId,
  }) async {
    final uuid = _categoryUuids[categoryId] ?? await _resolveUuid(categoryId);
    if (uuid == null) return null;
    final rows = await _gateway.rpc('get_price_band', <String, Object?>{
      'p_category_id': uuid,
      'p_urgency': urgency.name,
      'p_city_id': cityId,
    });
    // No row at all is the honest "no basis" answer — no hint, never a
    // zero band.
    final list = List<Map<String, dynamic>>.from(rows as List<dynamic>);
    if (list.isEmpty) return null;
    return priceBandFromRow(list.first);
  }

  Future<String?> _resolveUuid(String categoryKey) async {
    await getCategories();
    return _categoryUuids[categoryKey];
  }
}
