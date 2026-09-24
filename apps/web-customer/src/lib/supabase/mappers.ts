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
  GeoPoint,
  JobRequest,
  JobStatus,
  Money,
  Offer,
  OfferStatus,
  PlaceRef,
  PriceBand,
  PriceBreakdown,
  ServiceCategory,
  TrustLevel,
  Urgency,
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

// ---------------------------------------------------------------------------
// Requests + offers (W9.4)
// ---------------------------------------------------------------------------

const JOB_STATUS_WIRE: readonly JobStatus[] = [
  'draft',
  'published',
  'offers_received',
  'negotiating',
  'agreed',
  'payment_pending',
  'paid_held',
  'assigned',
  'en_route',
  'arrived',
  'in_progress',
  'completed_by_provider',
  'confirmed',
  'settlement_pending',
  'settled',
  'closed',
  'cancelled',
  'expired',
  'disputed',
  'refunded',
];

export function jobStatusFromWire(value: unknown): JobStatus {
  // Unknown values degrade to a terminal, non-actionable state.
  return JOB_STATUS_WIRE.includes(value as JobStatus)
    ? (value as JobStatus)
    : 'cancelled';
}

export function offerStatusFromWire(value: unknown): OfferStatus {
  switch (value) {
    case 'pending':
    case 'countered':
    case 'accepted':
    case 'declined':
    case 'withdrawn':
      return value;
    default:
      // Unknown values degrade to a terminal, non-actionable state.
      return 'expired';
  }
}

export function urgencyFromWire(value: unknown): Urgency {
  switch (value) {
    case 'flexible':
    case 'urgent':
    case 'emergency':
      return value;
    default:
      return 'standard';
  }
}

/** A PostGIS/GeoJSON point (`{type: 'Point', coordinates: [lng, lat]}`). */
export function geoPointFromWire(value: unknown): GeoPoint | undefined {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    return undefined;
  }
  const coords = (value as Row)['coordinates'];
  if (!Array.isArray(coords) || coords.length < 2) return undefined;
  const lng = typeof coords[0] === 'number' ? coords[0] : undefined;
  const lat = typeof coords[1] === 'number' ? coords[1] : undefined;
  if (lat === undefined || lng === undefined) return undefined;
  return { latitude: lat, longitude: lng };
}

function moneyOrNull(value: unknown, currency: string): Money | undefined {
  return value == null
    ? undefined
    : { amountMinor: SupabaseGateway.asMinorUnits(value), currency };
}

/** The `jobs` row joined to a request, mapped to the agreed-price breakdown.
 * Money columns stay null until the payment phase — the breakdown only exists
 * once the server has computed the commission (contract: jobs table). */
export function breakdownFromJobRow(
  jobRow: Row | null,
): PriceBreakdown | undefined {
  if (jobRow === null) return undefined;
  const gross = jobRow['agreed_amount_minor'];
  const commission = jobRow['commission_minor'];
  const net = jobRow['net_minor'];
  if (gross == null || commission == null || net == null) return undefined;
  const currency = (jobRow['currency'] as string | null) ?? 'NGN';
  return {
    gross: { amountMinor: SupabaseGateway.asMinorUnits(gross), currency },
    platformCommission: {
      amountMinor: SupabaseGateway.asMinorUnits(commission),
      currency,
    },
    net: { amountMinor: SupabaseGateway.asMinorUnits(net), currency },
    // The jobs table's net IS the provider payout basis (contract: jobs).
    providerPayout: { amountMinor: SupabaseGateway.asMinorUnits(net), currency },
    commissionRateBps: intOr(jobRow['commission_rate_bps'], 0),
    estimatedGatewayFee: moneyOrNull(
      jobRow['estimated_gateway_fee_minor'],
      currency,
    ),
    actualGatewayFee: moneyOrNull(jobRow['actual_gateway_fee_minor'], currency),
    tip: moneyOrNull(jobRow['tip_minor'], currency),
  };
}

function placeRef(
  label: string | null,
  point: unknown,
  landmarkNote: string | null,
): PlaceRef {
  return {
    label: label ?? '',
    point: geoPointFromWire(point),
    landmarkNote: landmarkNote ?? undefined,
  };
}

/** A `requests` row with the `service_categories(key)` embed and the to-one
 * `jobs` embed. PostgREST returns a reverse-FK to-one as either an object or
 * a single-element array depending on the uniqueness metadata — both are
 * accepted. [mediaPaths] come from `request_media` (loaded separately to
 * avoid an N+1 on list queries). */
export function jobRequestFromRow(row: Row, mediaPaths: string[] = []): JobRequest {
  const currency = (row['currency'] as string | null) ?? 'NGN';
  const isCustom = row['is_custom_category'] === true;
  const category = row['service_categories'];
  const categoryKey =
    category !== null && typeof category === 'object' && !Array.isArray(category)
      ? ((category as Row)['key'] as string | null)
      : null;
  const jobsRaw = row['jobs'];
  let jobRow: Row | null = null;
  if (jobsRaw !== null && typeof jobsRaw === 'object' && !Array.isArray(jobsRaw)) {
    jobRow = jobsRaw as Row;
  } else if (Array.isArray(jobsRaw) && jobsRaw.length > 0) {
    jobRow = jobsRaw[0] as Row;
  }
  const breakdown = breakdownFromJobRow(jobRow);
  const destinationLabel = row['destination_label'] as string | null;
  return {
    id: SupabaseGateway.asId(row['id']),
    customerId: SupabaseGateway.asId(row['customer_id']),
    categoryId: isCustom ? 'custom' : (categoryKey ?? 'custom'),
    isCustomCategory: isCustom,
    description: (row['description'] as string | null) ?? '',
    mediaPaths,
    pickup: placeRef(
      row['pickup_label'] as string | null,
      row['pickup_point'],
      row['pickup_landmark_note'] as string | null,
    ),
    destination:
      destinationLabel == null
        ? undefined
        : placeRef(
            destinationLabel,
            row['destination_point'],
            row['destination_landmark_note'] as string | null,
          ),
    urgency: urgencyFromWire(row['urgency']),
    status: jobStatusFromWire(row['status']),
    createdAt: SupabaseGateway.asTimestamp(row['created_at']),
    scheduledAt:
      row['scheduled_at'] == null
        ? undefined
        : SupabaseGateway.asTimestamp(row['scheduled_at']),
    preferredPrice: moneyOrNull(row['preferred_price_minor'], currency),
    itemFloat: moneyOrNull(row['item_float_minor'], currency),
    declaredValue: moneyOrNull(row['declared_value_minor'], currency),
    agreedPrice:
      jobRow === null
        ? undefined
        : moneyOrNull(jobRow['agreed_amount_minor'], currency),
    agreedBreakdown: breakdown,
    providerId: (jobRow?.['provider_id'] as string | null) ?? undefined,
    expiresAt:
      row['expires_at'] == null
        ? undefined
        : SupabaseGateway.asTimestamp(row['expires_at']),
    // handoverPin deliberately stays undefined: the contract hands PINs out
    // on demand via `reveal_job_pin` (job-progress slice), never on the row.
  };
}

/** An `offers` row. Provider display fields (name/rating/trust) come from a
 * `get_provider_card` row — the offers table deliberately does not denormalize
 * them. [card] is a `get_provider_card` row or null (unknown provider). */
export function offerFromRow(row: Row, card?: Row | null): Offer {
  const currency = (row['currency'] as string | null) ?? 'NGN';
  const ratingMilli = card?.['rating_avg_milli'];
  return {
    id: SupabaseGateway.asId(row['id']),
    requestId: SupabaseGateway.asId(row['request_id']),
    providerId: SupabaseGateway.asId(row['provider_id']),
    providerName: (card?.['display_name'] as string | null) ?? '',
    // rating_avg_milli is an integer milli-rating (4250 → 4.25 stars).
    providerRating:
      (typeof ratingMilli === 'number' ? Math.trunc(ratingMilli) : 0) / 1000,
    providerTrustLevel: trustLevelFromWire(card?.['trust_level']),
    amount: {
      amountMinor: SupabaseGateway.asMinorUnits(row['amount_minor']),
      currency,
    },
    status: offerStatusFromWire(row['status']),
    round: intOr(row['round'], 1),
    createdAt: SupabaseGateway.asTimestamp(row['created_at']),
    message: (row['message'] as string | null) ?? undefined,
    expiresAt:
      row['expires_at'] == null
        ? undefined
        : SupabaseGateway.asTimestamp(row['expires_at']),
    // distanceMeters / etaMinutes / payoutEstimate are rank_offers display
    // fields — deferred (HANDOFF M9.2 follow-up).
  };
}
