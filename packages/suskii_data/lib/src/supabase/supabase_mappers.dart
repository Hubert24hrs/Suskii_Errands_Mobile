import 'package:suskii_domain/suskii_domain.dart';

import 'supabase_gateway.dart';

/// Row/jsonb → domain mappings shared by the Supabase repositories. Wire
/// values come from contracts/v1; anything unrecognized maps to the safest
/// default rather than throwing, because a new enum value on the server must
/// not break an old build.

UserMode userModeFromWire(Object? value) =>
    value == 'provider' ? UserMode.provider : UserMode.customer;

VerificationStatus verificationFromWire(Object? value) => switch (value) {
  'pending' => VerificationStatus.pending,
  'in_review' => VerificationStatus.inReview,
  'verified' => VerificationStatus.verified,
  'rejected' => VerificationStatus.rejected,
  _ => VerificationStatus.unverified,
};

TrustLevel trustLevelFromWire(Object? value) => switch (value) {
  'verified' => TrustLevel.verified,
  'trusted' => TrustLevel.trusted,
  'elite' => TrustLevel.elite,
  _ => TrustLevel.new_,
};

CountryStatus countryStatusFromWire(Object? value) => switch (value) {
  'beta' => CountryStatus.beta,
  'live' => CountryStatus.live,
  _ => CountryStatus.disabled,
};

/// A `profiles` row (own row, RLS-scoped) merged with the GoTrue identity for
/// phone/email, which the table deliberately does not carry.
AppUser appUserFromProfileRow(
  Map<String, dynamic> row, {
  String? phoneE164,
  String? email,
}) => AppUser(
  // profiles rows key the id as user_id; get_bootstrap's user object as id.
  id: SupabaseGateway.asId(row['user_id'] ?? row['id']),
  displayName: row['display_name'] as String? ?? '',
  // Nullable on a fresh signup before onboarding completes.
  countryCode: row['country_code'] as String? ?? '',
  preferredLanguage: row['language'] as String? ?? 'en',
  activeMode: userModeFromWire(row['active_mode']),
  customerVerification: verificationFromWire(row['customer_verification']),
  providerVerification: verificationFromWire(row['provider_verification']),
  trustLevel: trustLevelFromWire(row['trust_level']),
  createdAt: row['created_at'] == null
      ? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)
      : SupabaseGateway.asTimestamp(row['created_at']),
  phoneE164: phoneE164,
  email: email,
  // avatar_path is a storage path, not a URL — signed URLs are a later M9
  // slice (storage gateway), so photoUrl stays null for now.
);

/// The `country_pack` object inside `get_bootstrap`'s payload. Fields the
/// server pack does not carry yet (emergency numbers, launch cities beyond
/// the cities table, per-country TTL overrides) fall back to the spec
/// defaults — tracked in HANDOFF (M9.1 follow-ups).
CountryPack countryPackFromBootstrap(
  Map<String, dynamic> pack, {
  List<String> launchCities = const <String>[],
}) {
  final currency = pack['currency'] as Map<String, dynamic>? ?? const {};
  final client = pack['client'] as Map<String, dynamic>? ?? const {};
  final emergency = client['emergency_numbers'] as List<dynamic>? ?? const [];
  return CountryPack(
    countryCode: pack['code'] as String,
    status: countryStatusFromWire(pack['status']),
    currencyCode: currency['code'] as String? ?? 'NGN',
    supportedLanguages:
        (pack['supported_languages'] as List<dynamic>? ?? const ['en'])
            .cast<String>(),
    defaultLanguage: pack['default_language'] as String? ?? 'en',
    launchCities: launchCities,
    emergencyNumbers: <EmergencyNumber>[
      for (final e in emergency)
        if (e is Map<String, dynamic>)
          EmergencyNumber(
            labelKey: e['label_key'] as String? ?? 'sosEmergencyGeneral',
            number: e['number'] as String? ?? '',
          ),
    ],
    offerTtlSeconds: (client['offer_ttl_seconds'] as num?)?.toInt() ?? 600,
    maxNegotiationRounds: (client['max_counter_rounds'] as num?)?.toInt() ?? 5,
  );
}

/// A `notifications` row. NOTE (M9 alignment, tracked in HANDOFF): the wire
/// carries title_key/body_key/params and never text; the domain model still
/// has pre-rendered title/body from the mock era, so the keys are mapped
/// through verbatim until the notification-center slice switches the model
/// to keys + params and renders from ARB.
AppNotification appNotificationFromRow(Map<String, dynamic> row) =>
    AppNotification(
      id: SupabaseGateway.asId(row['id']),
      kind: row['kind'] as String? ?? '',
      title: row['title_key'] as String? ?? '',
      body: row['body_key'] as String? ?? '',
      read: row['read_at'] != null,
      createdAt: SupabaseGateway.asTimestamp(row['created_at']),
      deeplink: row['deep_link'] as String?,
    );

/// A `get_price_band` row. Confidence is a display bucketing derived from the
/// sample size (not money arithmetic).
PriceBand priceBandFromRow(Map<String, dynamic> row) {
  final currency = row['currency'] as String;
  final sampleSize = (row['sample_size'] as num).toInt();
  return PriceBand(
    p25: Money(SupabaseGateway.asMinorUnits(row['p25_minor']), currency),
    p50: Money(SupabaseGateway.asMinorUnits(row['p50_minor']), currency),
    p75: Money(SupabaseGateway.asMinorUnits(row['p75_minor']), currency),
    sampleSize: sampleSize,
    confidence: sampleSize < 30
        ? PriceBandConfidence.low
        : sampleSize < 100
        ? PriceBandConfidence.medium
        : PriceBandConfidence.high,
    basis: row['basis'] == 'history'
        ? PriceBandBasis.history
        : PriceBandBasis.rules,
  );
}

/// A `service_categories` row. The domain `id` stays the category KEY (the
/// seed guarantees keys match the app fixtures and `create_request` resolves
/// `category_key`); the uuid is kept only in the repository's key→uuid map
/// for the RPCs that take `category_id`.
ServiceCategory serviceCategoryFromRow(Map<String, dynamic> row) {
  final requirements = <String, int>{};
  final raw = row['proof_requirements'];
  if (raw is Map<String, dynamic>) {
    for (final entry in raw.entries) {
      final count = (entry.value as num?)?.toInt() ?? 0;
      if (count > 0) requirements[entry.key] = count;
    }
  }
  return ServiceCategory(
    id: row['key'] as String,
    labelKey: row['name_key'] as String? ?? 'catCustom',
    iconKey: row['icon_key'] as String? ?? 'magic',
    allowsCustom: row['allows_custom'] as bool? ?? false,
    offerTtlSeconds: (row['offer_ttl_seconds'] as num?)?.toInt() ?? 600,
    maxCounterRounds: (row['max_counter_rounds'] as num?)?.toInt() ?? 5,
    proofRequirements: requirements,
  );
}
