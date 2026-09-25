// Row/jsonb → domain mappings for the web Supabase repositories, mirroring
// packages/suskii_data/lib/src/supabase/supabase_mappers.dart. Wire values
// come from contracts/v1; anything unrecognized maps to the safest default
// rather than throwing, because a new enum value on the server must not
// break an old build.

import type {
  AppNotification,
  AppUser,
  ChatMessage,
  ChatMessageType,
  CountryPack,
  CountryStatus,
  Dispute,
  DisputeStatus,
  GeoPoint,
  JobRequest,
  JobStatus,
  Money,
  NotificationPreferences,
  Offer,
  OfferStatus,
  Payment,
  PaymentMethod,
  PaymentStatus,
  PlaceRef,
  PriceBand,
  PriceBreakdown,
  Rating,
  ServiceCategory,
  SosAlert,
  SosStatus,
  SupportMessage,
  SupportTicket,
  SupportTicketStatus,
  TrustLevel,
  TrustedContact,
  Urgency,
  UserMode,
  VerificationStatus,
  WalletTransaction,
  WalletTransactionKind,
  WalletTransactionStatus,
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

// ---------------------------------------------------------------------------
// Payments, ratings, safety (W9.5)
// ---------------------------------------------------------------------------

export function paymentStatusFromWire(value: unknown): PaymentStatus {
  switch (value) {
    case 'pending':
    case 'held':
    case 'failed':
    case 'refunded':
    case 'partially_refunded':
      return value;
    default:
      return 'unpaid';
  }
}

export function paymentMethodFromWire(value: unknown): PaymentMethod {
  switch (value) {
    case 'bank_transfer':
    case 'mobile_money':
    case 'ussd':
      return value;
    default:
      return 'card';
  }
}

export function paymentMethodToWire(method: PaymentMethod): string {
  return method;
}

/** A `payments` row. Column grants deliberately exclude `checkout_url` (it
 * comes from `get_payment_checkout`), so the entity never carries it.
 * `method` is nullable on the wire until start_payment fills it in; the safe
 * default renders as card. */
export function paymentFromRow(row: Row): Payment {
  return {
    id: SupabaseGateway.asId(row['id']),
    jobId: SupabaseGateway.asId(row['request_id']),
    amount: {
      amountMinor: SupabaseGateway.asMinorUnits(row['amount_minor']),
      currency: (row['currency'] as string | null) ?? 'NGN',
    },
    method: paymentMethodFromWire(row['method']),
    status: paymentStatusFromWire(row['status']),
    createdAt: SupabaseGateway.asTimestamp(row['created_at']),
    gatewayReference: (row['gateway_reference'] as string | null) ?? undefined,
    paidAt:
      row['confirmed_at'] == null
        ? undefined
        : SupabaseGateway.asTimestamp(row['confirmed_at']),
    expiresAt:
      row['expires_at'] == null
        ? undefined
        : SupabaseGateway.asTimestamp(row['expires_at']),
    failureReasonKey: (row['failed_reason_key'] as string | null) ?? undefined,
  };
}

/** A `ratings` row (RLS scopes visibility to rater/ratee). `tags` are the
 * localization keys the rater picked. */
export function ratingFromRow(row: Row): Rating {
  const tags = row['tags'];
  return {
    id: SupabaseGateway.asId(row['id']),
    jobId: SupabaseGateway.asId(row['request_id']),
    raterId: SupabaseGateway.asId(row['rater_id']),
    rateeId: SupabaseGateway.asId(row['ratee_id']),
    stars: intOr(row['stars'], 0),
    tagKeys: Array.isArray(tags) ? (tags as string[]) : [],
    comment: (row['comment'] as string | null) ?? undefined,
    createdAt: SupabaseGateway.asTimestamp(row['created_at']),
  };
}

/** The wire `sos_status` enum is richer than the entity's (open, acknowledged,
 * dispatched, resolved, false_alarm): the three in-flight values all render
 * as "active" in the app; false_alarm reads as resolved. */
export function sosStatusFromWire(value: unknown): SosStatus {
  return value === 'resolved' || value === 'false_alarm' ? 'resolved' : 'active';
}

/** An `sos_incidents` row. `request_id` is nullable on the wire (SOS can be
 * raised outside a job); the entity requires a job id, so a jobless alert
 * carries an empty one — the SOS UI only exists inside a job today. */
export function sosAlertFromRow(row: Row): SosAlert {
  return {
    id: SupabaseGateway.asId(row['id']),
    jobId: (row['request_id'] as string | null) ?? '',
    triggeredBy: SupabaseGateway.asId(row['raised_by']),
    status: sosStatusFromWire(row['status']),
    createdAt: SupabaseGateway.asTimestamp(row['created_at']),
    location: geoPointFromWire(row['point']),
    trustedContactsNotified: intOr(row['trusted_contacts_notified'], 0),
  };
}

// ---------------------------------------------------------------------------
// Wallet, referrals, disputes (W9.6)
// ---------------------------------------------------------------------------

export function disputeStatusFromWire(value: unknown): DisputeStatus {
  switch (value) {
    case 'under_review':
      return 'in_review';
    case 'resolved':
      return 'resolved';
    case 'rejected':
      return 'rejected';
    case 'withdrawn':
      return 'withdrawn';
    default:
      // Unknown values render as open (still active) rather than closing a
      // dispute the user may still need to act on.
      return 'open';
  }
}

/** A `disputes` row with the `requests(currency)` embed (the table itself
 * carries no currency, so the refund money needs the request's). Evidence
 * paths come from `dispute_evidence`, loaded separately. */
export function disputeFromRow(row: Row, evidencePaths: string[] = []): Dispute {
  const request = row['requests'];
  const currency =
    request !== null && typeof request === 'object' && !Array.isArray(request)
      ? ((request as Row)['currency'] as string | null) ?? 'NGN'
      : 'NGN';
  return {
    id: SupabaseGateway.asId(row['id']),
    jobId: SupabaseGateway.asId(row['request_id']),
    openedBy: SupabaseGateway.asId(row['opened_by']),
    reasonKey: (row['reason_code'] as string | null) ?? '',
    status: disputeStatusFromWire(row['status']),
    createdAt: SupabaseGateway.asTimestamp(row['created_at']),
    details: (row['description'] as string | null) ?? undefined,
    evidencePaths: evidencePaths.length === 0 ? undefined : evidencePaths,
    slaDeadline:
      row['sla_due_at'] == null
        ? undefined
        : SupabaseGateway.asTimestamp(row['sla_due_at']),
    resolutionNoteKey: (row['resolution_key'] as string | null) ?? undefined,
    refundAmount: moneyOrNull(row['refund_minor'], currency),
  };
}

/** A `withdrawals` row rendered as a wallet transaction. PROVISIONAL until
 * CR-20260923-03 lands a client-readable ledger: the private double-entry
 * ledger is deliberately not exposed, so withdrawals are the only real
 * wallet-history rows the contract offers today.
 * Divergence from Dart: the web enum has a native `awaiting_approval` status
 * (M8.6), so the wire value maps to it directly instead of folding to
 * pending + a description key. */
export function withdrawalTransactionFromRow(
  row: Row,
  kind: WalletTransactionKind,
): WalletTransaction {
  const status = (row['status'] as string | null) ?? 'requested';
  return {
    id: SupabaseGateway.asId(row['id']),
    kind,
    status: ((): WalletTransactionStatus => {
      switch (status) {
        case 'paid':
          return 'completed';
        case 'failed':
        case 'rejected':
          return 'failed';
        case 'awaiting_approval':
          return 'awaiting_approval';
        default:
          return 'pending';
      }
    })(),
    amount: {
      amountMinor: SupabaseGateway.asMinorUnits(row['amount_minor']),
      currency: (row['currency'] as string | null) ?? 'NGN',
    },
    createdAt: SupabaseGateway.asTimestamp(row['created_at']),
    descriptionKey:
      status === 'awaiting_approval'
        ? 'txnWithdrawalAwaitingApproval'
        : 'txnWithdrawal',
  };
}

/** Aggregates `my_referral_summary` rows (currency, status, commissions,
 * amount_minor) into the entity's totals: `available` is the withdrawable
 * balance, `holding` is everything not yet withdrawable (pending/earned/
 * holding), `earnedTotal` is the lifetime total excluding reversed
 * commissions. Statuses the client doesn't know yet count toward holding
 * rather than vanishing. */
export function referralTotalsFromRows(
  rows: Row[],
  currency: string,
): { earnedTotal: Money; holding: Money; available: Money } {
  let available = 0;
  let holding = 0;
  for (const row of rows) {
    const amount = SupabaseGateway.asMinorUnits(row['amount_minor']);
    switch (row['status']) {
      case 'available':
        available += amount;
        break;
      case 'reversed':
        break;
      default:
        holding += amount;
    }
  }
  return {
    earnedTotal: { amountMinor: available + holding, currency },
    holding: { amountMinor: holding, currency },
    available: { amountMinor: available, currency },
  };
}

// ---------------------------------------------------------------------------
// Chat + tracking (W9.7)
// ---------------------------------------------------------------------------

export function chatMessageTypeFromWire(value: unknown): ChatMessageType {
  switch (value) {
    case 'image':
    case 'voice_note':
    case 'location':
    case 'offer_card':
    case 'system':
      return value;
    default:
      return 'text';
  }
}

/** Web enum values ARE the wire values — identity, kept for symmetry with
 * the other toWire mappers. */
export function chatMessageTypeToWire(type: ChatMessageType): string {
  return type;
}

/** A `messages` row. The job id comes from the `conversations(request_id)`
 * embed (messages key on conversation, not request); the embed is a
 * many-to-one object, with the single-element array tolerated as elsewhere.
 * `id` is a bigint — held as an opaque string, never a number. [readAt] is
 * derived from the OTHER participant's `message_reads` pointer — the wire
 * has no per-message read timestamp. */
export function chatMessageFromRow(
  row: Row,
  options: { jobId?: string; readAt?: Date } = {},
): ChatMessage {
  const conversation = row['conversations'];
  let embeddedJobId: string | null = null;
  if (
    conversation !== null &&
    typeof conversation === 'object' &&
    !Array.isArray(conversation)
  ) {
    embeddedJobId = ((conversation as Row)['request_id'] as string | null) ?? null;
  } else if (Array.isArray(conversation) && conversation.length > 0) {
    embeddedJobId = ((conversation[0] as Row)['request_id'] as string | null) ?? null;
  }
  return {
    id: SupabaseGateway.asId(row['id']),
    jobId: embeddedJobId ?? options.jobId ?? '',
    senderId: SupabaseGateway.asId(row['sender_id']),
    type: chatMessageTypeFromWire(row['type']),
    createdAt: SupabaseGateway.asTimestamp(row['created_at']),
    text: (row['body'] as string | null) ?? undefined,
    mediaPath: (row['media_path'] as string | null) ?? undefined,
    offerId: (row['offer_id'] as string | null) ?? undefined,
    location: geoPointFromWire(row['location']),
    readAt: options.readAt,
  };
}

/** bigint comparison without number precision: both sides are parsed from
 * their string form (message ids can in principle exceed 2^53). */
export function messageIdAtMost(a: unknown, b: unknown): boolean {
  return BigInt(String(a)) <= BigInt(String(b));
}

// ---------------------------------------------------------------------------
// Support + settings (W9.8)
// ---------------------------------------------------------------------------

export function supportTicketStatusFromWire(value: unknown): SupportTicketStatus {
  switch (value) {
    case 'waiting_on_user':
      return 'awaiting_user';
    case 'waiting_on_support':
      return 'awaiting_support';
    case 'resolved':
      return 'resolved';
    case 'closed':
      return 'closed';
    default:
      return 'open';
  }
}

/** A `support_tickets` row. The wire has no subject field — the category
 * plays that role in the entity. Messages are assembled by the repository
 * (batch-fetched from `ticket_messages` and grouped client-side). */
export function supportTicketFromRow(
  row: Row,
  messages: SupportMessage[] = [],
): SupportTicket {
  return {
    id: SupabaseGateway.asId(row['id']),
    subject: (row['category'] as string | null) ?? '',
    status: supportTicketStatusFromWire(row['status']),
    createdAt: SupabaseGateway.asTimestamp(row['created_at']),
    messages,
  };
}

/** A `ticket_messages` row. `fromUser` is derived by comparing `author_id`
 * with the signed-in user's auth id. The wire marks AI triage on the ticket
 * (`ai_triage` jsonb), not per message, so `aiTriage` is always false
 * here — see HANDOFF M9.7. */
export function supportMessageFromRow(row: Row, myId: string): SupportMessage {
  return {
    id: SupabaseGateway.asId(row['id']),
    body: (row['body'] as string | null) ?? '',
    fromUser: row['author_id'] === myId,
    createdAt: SupabaseGateway.asTimestamp(row['created_at']),
    aiTriage: false,
  };
}

/** A `trusted_contacts` row. The phone number is stored encrypted
 * (`phone_ciphertext` + blind index) and never returned in plaintext, so
 * the entity's `phoneE164` cannot be populated — tracked as CR-20260923-06. */
export function trustedContactFromRow(row: Row): TrustedContact {
  return {
    id: SupabaseGateway.asId(row['id']),
    name: (row['name'] as string | null) ?? '',
    phoneE164: '',
  };
}

/** Postgres `time` column → minutes since midnight ('HH:MM:SS'). */
export function quietMinutesFromWire(value: unknown): number | undefined {
  if (typeof value !== 'string') return undefined;
  const parts = value.split(':');
  if (parts.length < 2) return undefined;
  const hour = Number.parseInt(parts[0], 10);
  const minute = Number.parseInt(parts[1], 10);
  if (Number.isNaN(hour) || Number.isNaN(minute)) return undefined;
  return hour * 60 + minute;
}

/** Minutes since midnight → Postgres `time` literal ('HH:MM:SS'). */
export function quietMinutesToWire(minutes: number | undefined): string | null {
  if (minutes === undefined) return null;
  const hour = Math.floor(minutes / 60).toString().padStart(2, '0');
  const minute = (minutes % 60).toString().padStart(2, '0');
  return `${hour}:${minute}:00`;
}

/** Composes the flat preferences entity from `notification_preferences`
 * rows: push/sms/email read the (channel, 'transactional') rows, marketing
 * reads the ('push', 'marketing') row. Missing rows default to enabled
 * (matching the mock defaults); quiet hours come from any row that has
 * them. */
export function notificationPreferencesFromRows(
  rows: Row[],
): NotificationPreferences {
  const enabledFor = (channel: string, category: string): boolean => {
    for (const row of rows) {
      if (row['channel'] === channel && row['category'] === category) {
        return (row['enabled'] as boolean | null) ?? true;
      }
    }
    return true;
  };
  let quietStart: number | undefined;
  let quietEnd: number | undefined;
  for (const row of rows) {
    quietStart ??= quietMinutesFromWire(row['quiet_start']);
    quietEnd ??= quietMinutesFromWire(row['quiet_end']);
  }
  return {
    push: enabledFor('push', 'transactional'),
    sms: enabledFor('sms', 'transactional'),
    email: enabledFor('email', 'transactional'),
    marketing: enabledFor('push', 'marketing'),
    quietStartMinutes: quietStart,
    quietEndMinutes: quietEnd,
  };
}

/** Explodes the flat preferences entity into `notification_preferences`
 * rows for upsert (PK: user_id, channel, category). The quiet window is
 * applied to every row. */
export function notificationPreferenceRows(
  userId: string,
  prefs: NotificationPreferences,
): Row[] {
  const quietStart = quietMinutesToWire(prefs.quietStartMinutes);
  const quietEnd = quietMinutesToWire(prefs.quietEndMinutes);
  const row = (channel: string, category: string, enabled: boolean): Row => ({
    user_id: userId,
    channel,
    category,
    enabled,
    quiet_start: quietStart,
    quiet_end: quietEnd,
  });
  return [
    row('push', 'transactional', prefs.push),
    row('sms', 'transactional', prefs.sms),
    row('email', 'transactional', prefs.email),
    row('push', 'marketing', prefs.marketing),
  ];
}
