// Row/jsonb → domain mappings for the web Supabase repositories, mirroring
// packages/suskii_data/lib/src/supabase/supabase_mappers.dart. Wire values
// come from contracts/v1; anything unrecognized maps to the safest default
// rather than throwing, because a new enum value on the server must not
// break an old build.

import type {
  AppNotification,
  AppUser,
  CountryPack,
  CountryStatus,
  PriceBand,
  ServiceCategory,
  TrustLevel,
  UserMode,
  VerificationStatus,
} from '@/mocks/types';

import { SupabaseGateway, type Row } from './gateway';

/// Column list for the caller's own `profiles` row (explicit lists — a `*`
/// naming an ungranted column fails the whole query).
export const profileRowColumns =
  'user_id, display_name, country_code, language, avatar_path, ' +
  'active_mode, customer_verification, provider_verification, ' +
  'trust_level, created_at';

const VERIFICATION_STATUSES: readonly VerificationStatus[] = [
  'unverified',
  'pending',
  'in_review',
  'verified',
  'rejected',
  'suspended',
  'expired',
];

export function userModeFromWire(value: unknown): UserMode {
  return value === 'provider' ? 'provider' : 'customer';
}

export function verificationFromWire(value: unknown): VerificationStatus {
  return VERIFICATION_STATUSES.includes(value as VerificationStatus)
    ? (value as VerificationStatus)
    : 'unverified';
}

export function trustLevelFromWire(value: unknown): TrustLevel {
  switch (value) {
    case 'verified':
    case 'trusted':
    case 'elite':
      return value;
    default:
      return 'new';
  }
}

/** A `profiles` row (own row, RLS-scoped) merged with the GoTrue identity
 * for phone/email, which the table deliberately does not carry. */
export function appUserFromProfileRow(
  row: Row,
  identity: { phoneE164?: string; email?: string } = {},
): AppUser {
  // profiles rows key the id as user_id; get_bootstrap's user object as id.
  const createdAt = row['created_at'];
  return {
    id: SupabaseGateway.asId(row['user_id'] ?? row['id']),
    displayName: (row['display_name'] as string | null) ?? '',
    // Nullable on a fresh signup before onboarding completes.
    countryCode: (row['country_code'] as string | null) ?? '',
    preferredLanguage: (row['language'] as string | null) ?? 'en',
    activeMode: userModeFromWire(row['active_mode']),
    customerVerification: verificationFromWire(row['customer_verification']),
    providerVerification: verificationFromWire(row['provider_verification']),
    trustLevel: trustLevelFromWire(row['trust_level']),
    createdAt:
      createdAt == null ? new Date(0) : SupabaseGateway.asTimestamp(createdAt),
    phoneE164: identity.phoneE164,
    email: identity.email,
    // avatar_path is a storage path, not a URL — signed URLs are a later
    // slice (storage gateway), so photoUrl stays undefined for now.
  };
}

// ---------------------------------------------------------------------------
// Bootstrap + catalog (W9.3)
// ---------------------------------------------------------------------------

export function countryStatusFromWire(value: unknown): CountryStatus {
  switch (value) {
    case 'beta':
    case 'live':
      return value;
    default:
      return 'disabled';
  }
}

function intOr(value: unknown, fallback: number): number {
  return typeof value === 'number' ? Math.trunc(value) : fallback;
}

/** The `country_pack` object inside `get_bootstrap`'s payload. Fields the
 * server pack does not carry yet (emergency numbers, per-country TTL
 * overrides) fall back to the spec defaults — tracked in HANDOFF (mobile
 * M9.1 follow-ups). Never invent values: read what is present, default the
 * rest. */
export function countryPackFromBootstrap(
  pack: Row,
  launchCities: string[] = [],
): CountryPack {
  const currency = (pack['currency'] as Row | null) ?? {};
  const client = (pack['client'] as Row | null) ?? {};
  const emergency = Array.isArray(client['emergency_numbers'])
    ? (client['emergency_numbers'] as unknown[])
    : [];
  const languages = pack['supported_languages'];
  return {
    countryCode: pack['code'] as string,
    status: countryStatusFromWire(pack['status']),
    currencyCode: (currency['code'] as string | null) ?? 'NGN',
    supportedLanguages: Array.isArray(languages)
      ? (languages as string[])
      : ['en'],
    defaultLanguage: (pack['default_language'] as string | null) ?? 'en',
    launchCities,
    emergencyNumbers: emergency
      .filter((e): e is Row => typeof e === 'object' && e !== null)
      .map((e) => ({
        labelKey: (e['label_key'] as string | null) ?? 'sosEmergencyGeneral',
        number: (e['number'] as string | null) ?? '',
      })),
    offerTtlSeconds: intOr(client['offer_ttl_seconds'], 600),
    maxNegotiationRounds: intOr(client['max_counter_rounds'], 5),
  };
}

/** A `notifications` row. The wire carries title_key/body_key/params and
 * never text; the model still has pre-rendered title/body from the mock era,
 * so the keys map through verbatim until the notification-center slice
 * switches the model to keys + params and renders from the dictionary. */
export function appNotificationFromRow(row: Row): AppNotification {
  return {
    id: SupabaseGateway.asId(row['id']),
    kind: (row['kind'] as string | null) ?? '',
    title: (row['title_key'] as string | null) ?? '',
    body: (row['body_key'] as string | null) ?? '',
    read: row['read_at'] != null,
    createdAt: SupabaseGateway.asTimestamp(row['created_at']),
    deeplink: (row['deep_link'] as string | null) ?? undefined,
  };
}

/** A `get_price_band` row. Confidence is a display bucketing derived from
 * the sample size (not money arithmetic). */
export function priceBandFromRow(row: Row): PriceBand {
  const currency = row['currency'] as string;
  const sampleSize = intOr(row['sample_size'], 0);
  return {
    p25: {
      amountMinor: SupabaseGateway.asMinorUnits(row['p25_minor']),
      currency,
    },
    p50: {
      amountMinor: SupabaseGateway.asMinorUnits(row['p50_minor']),
      currency,
    },
    p75: {
      amountMinor: SupabaseGateway.asMinorUnits(row['p75_minor']),
      currency,
    },
    sampleSize,
    confidence: sampleSize < 30 ? 'low' : sampleSize < 100 ? 'medium' : 'high',
    basis: row['basis'] === 'history' ? 'history' : 'rules',
  };
}

/** A `service_categories` row. The entity `id` stays the category KEY (the
 * seed guarantees keys match the app fixtures and `create_request` resolves
 * `category_key`); the uuid is kept only in the repository's key→uuid map
 * for the RPCs that take `category_id`. */
export function serviceCategoryFromRow(row: Row): ServiceCategory {
  const requirements: Record<string, number> = {};
  const raw = row['proof_requirements'];
  if (raw !== null && typeof raw === 'object' && !Array.isArray(raw)) {
    for (const [kind, count] of Object.entries(raw as Row)) {
      const n = typeof count === 'number' ? Math.trunc(count) : 0;
      if (n > 0) requirements[kind] = n;
    }
  }
  return {
    id: row['key'] as string,
    labelKey: (row['name_key'] as string | null) ?? 'catCustom',
    iconKey: (row['icon_key'] as string | null) ?? 'magic',
    allowsCustom: row['allows_custom'] === true,
    offerTtlSeconds: intOr(row['offer_ttl_seconds'], 600),
    maxCounterRounds: intOr(row['max_counter_rounds'], 5),
    proofRequirements: requirements,
  };
}
