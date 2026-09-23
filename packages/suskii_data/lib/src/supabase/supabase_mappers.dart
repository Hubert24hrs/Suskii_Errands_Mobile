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

JobStatus jobStatusFromWire(Object? value) => switch (value) {
  'draft' => JobStatus.draft,
  'published' => JobStatus.published,
  'offers_received' => JobStatus.offersReceived,
  'negotiating' => JobStatus.negotiating,
  'agreed' => JobStatus.agreed,
  'payment_pending' => JobStatus.paymentPending,
  'paid_held' => JobStatus.paidHeld,
  'assigned' => JobStatus.assigned,
  'en_route' => JobStatus.enRoute,
  'arrived' => JobStatus.arrived,
  'in_progress' => JobStatus.inProgress,
  'completed_by_provider' => JobStatus.completedByProvider,
  'confirmed' => JobStatus.confirmed,
  'settlement_pending' => JobStatus.settlementPending,
  'settled' => JobStatus.settled,
  'closed' => JobStatus.closed,
  'expired' => JobStatus.expired,
  'disputed' => JobStatus.disputed,
  'refunded' => JobStatus.refunded,
  // Unknown values degrade to a terminal, non-actionable state.
  _ => JobStatus.cancelled,
};

String jobStatusToWire(JobStatus status) => switch (status) {
  JobStatus.draft => 'draft',
  JobStatus.published => 'published',
  JobStatus.offersReceived => 'offers_received',
  JobStatus.negotiating => 'negotiating',
  JobStatus.agreed => 'agreed',
  JobStatus.paymentPending => 'payment_pending',
  JobStatus.paidHeld => 'paid_held',
  JobStatus.assigned => 'assigned',
  JobStatus.enRoute => 'en_route',
  JobStatus.arrived => 'arrived',
  JobStatus.inProgress => 'in_progress',
  JobStatus.completedByProvider => 'completed_by_provider',
  JobStatus.confirmed => 'confirmed',
  JobStatus.settlementPending => 'settlement_pending',
  JobStatus.settled => 'settled',
  JobStatus.closed => 'closed',
  JobStatus.cancelled => 'cancelled',
  JobStatus.expired => 'expired',
  JobStatus.disputed => 'disputed',
  JobStatus.refunded => 'refunded',
};

OfferStatus offerStatusFromWire(Object? value) => switch (value) {
  'pending' => OfferStatus.pending,
  'countered' => OfferStatus.countered,
  'accepted' => OfferStatus.accepted,
  'declined' => OfferStatus.declined,
  'withdrawn' => OfferStatus.withdrawn,
  // Unknown values degrade to a terminal, non-actionable state.
  _ => OfferStatus.expired,
};

Urgency urgencyFromWire(Object? value) => switch (value) {
  'flexible' => Urgency.flexible,
  'urgent' => Urgency.urgent,
  'emergency' => Urgency.emergency,
  _ => Urgency.standard,
};

/// A PostGIS/GeoJSON point (`{type: 'Point', coordinates: [lng, lat]}`).
GeoPoint? geoPointFromWire(Object? value) {
  if (value is! Map<String, dynamic>) return null;
  final coords = value['coordinates'];
  if (coords is! List<dynamic> || coords.length < 2) return null;
  final lng = (coords[0] as num?)?.toDouble();
  final lat = (coords[1] as num?)?.toDouble();
  if (lat == null || lng == null) return null;
  return GeoPoint(latitude: lat, longitude: lng);
}

Money? moneyOrNull(Object? minorUnits, String currency) => minorUnits == null
    ? null
    : Money(SupabaseGateway.asMinorUnits(minorUnits), currency);

/// The `jobs` row joined to a request, mapped to the agreed-price breakdown.
/// Money columns stay null until the payment phase — the breakdown only
/// exists once the server has computed the commission (contract: jobs table).
PriceBreakdown? breakdownFromJobRow(Map<String, dynamic>? jobRow) {
  if (jobRow == null) return null;
  final gross = jobRow['agreed_amount_minor'];
  final commission = jobRow['commission_minor'];
  final net = jobRow['net_minor'];
  if (gross == null || commission == null || net == null) return null;
  final currency = jobRow['currency'] as String? ?? 'NGN';
  return PriceBreakdown(
    gross: Money(SupabaseGateway.asMinorUnits(gross), currency),
    platformCommission: Money(
      SupabaseGateway.asMinorUnits(commission),
      currency,
    ),
    net: Money(SupabaseGateway.asMinorUnits(net), currency),
    // The jobs table's net IS the provider payout basis (contract: jobs).
    providerPayout: Money(SupabaseGateway.asMinorUnits(net), currency),
    commissionRateBps: (jobRow['commission_rate_bps'] as num?)?.toInt() ?? 0,
    estimatedGatewayFee: moneyOrNull(
      jobRow['estimated_gateway_fee_minor'],
      currency,
    ),
    actualGatewayFee: moneyOrNull(jobRow['actual_gateway_fee_minor'], currency),
    tip: moneyOrNull(jobRow['tip_minor'], currency),
  );
}

PlaceRef _placeRef(String? label, Object? point, String? landmarkNote) =>
    PlaceRef(
      label: label ?? '',
      point: geoPointFromWire(point),
      landmarkNote: landmarkNote,
    );

/// A `requests` row with the `service_categories(key)` embed and the to-one
/// `jobs` embed. PostgREST returns a reverse-FK to-one as either an object or
/// a single-element array depending on the uniqueness metadata — both are
/// accepted. [mediaPaths] come from `request_media` (loaded separately to
/// avoid an N+1 on list queries).
JobRequest jobRequestFromRow(
  Map<String, dynamic> row, {
  List<String> mediaPaths = const <String>[],
}) {
  final currency = row['currency'] as String? ?? 'NGN';
  final isCustom = row['is_custom_category'] as bool? ?? false;
  final category = row['service_categories'];
  final categoryKey = category is Map<String, dynamic>
      ? category['key'] as String?
      : null;
  final jobsRaw = row['jobs'];
  Map<String, dynamic>? jobRow;
  if (jobsRaw is Map<String, dynamic>) {
    jobRow = jobsRaw;
  } else if (jobsRaw is List<dynamic> && jobsRaw.isNotEmpty) {
    jobRow = jobsRaw.first as Map<String, dynamic>;
  }
  final breakdown = breakdownFromJobRow(jobRow);
  final destinationLabel = row['destination_label'] as String?;
  return JobRequest(
    id: SupabaseGateway.asId(row['id']),
    customerId: SupabaseGateway.asId(row['customer_id']),
    categoryId: isCustom ? 'custom' : (categoryKey ?? 'custom'),
    isCustomCategory: isCustom,
    description: row['description'] as String? ?? '',
    mediaPaths: mediaPaths,
    pickup: _placeRef(
      row['pickup_label'] as String?,
      row['pickup_point'],
      row['pickup_landmark_note'] as String?,
    ),
    destination: destinationLabel == null
        ? null
        : _placeRef(
            destinationLabel,
            row['destination_point'],
            row['destination_landmark_note'] as String?,
          ),
    urgency: urgencyFromWire(row['urgency']),
    status: jobStatusFromWire(row['status']),
    createdAt: SupabaseGateway.asTimestamp(row['created_at']),
    scheduledAt: row['scheduled_at'] == null
        ? null
        : SupabaseGateway.asTimestamp(row['scheduled_at']),
    preferredPrice: moneyOrNull(row['preferred_price_minor'], currency),
    itemFloat: moneyOrNull(row['item_float_minor'], currency),
    declaredValue: moneyOrNull(row['declared_value_minor'], currency),
    agreedPrice: jobRow == null
        ? null
        : moneyOrNull(jobRow['agreed_amount_minor'], currency),
    agreedBreakdown: breakdown,
    providerId: jobRow?['provider_id'] as String?,
    expiresAt: row['expires_at'] == null
        ? null
        : SupabaseGateway.asTimestamp(row['expires_at']),
  );
}

/// An `offers` row. Provider display fields (name/rating/trust) come from a
/// `get_provider_card` row — the offers table deliberately does not denormalize
/// them. [card] is a `get_provider_card` row or null (unknown provider).
Offer offerFromRow(Map<String, dynamic> row, {Map<String, dynamic>? card}) {
  final currency = row['currency'] as String? ?? 'NGN';
  return Offer(
    id: SupabaseGateway.asId(row['id']),
    requestId: SupabaseGateway.asId(row['request_id']),
    providerId: SupabaseGateway.asId(row['provider_id']),
    providerName: card?['display_name'] as String? ?? '',
    // rating_avg_milli is an integer milli-rating (4250 → 4.25 stars).
    providerRating: ((card?['rating_avg_milli'] as num?)?.toInt() ?? 0) / 1000,
    providerTrustLevel: trustLevelFromWire(card?['trust_level']),
    amount: Money(SupabaseGateway.asMinorUnits(row['amount_minor']), currency),
    status: offerStatusFromWire(row['status']),
    round: (row['round'] as num?)?.toInt() ?? 1,
    createdAt: SupabaseGateway.asTimestamp(row['created_at']),
    message: row['message'] as String?,
    expiresAt: row['expires_at'] == null
        ? null
        : SupabaseGateway.asTimestamp(row['expires_at']),
    // distanceMeters / etaMinutes / payoutEstimate are rank_offers display
    // fields — deferred (HANDOFF M9.2 follow-up).
  );
}

// ---------------------------------------------------------------------------
// M9.3: payments, job progress (PINs/proofs), ratings, safety.
// ---------------------------------------------------------------------------

PaymentStatus paymentStatusFromWire(Object? value) => switch (value) {
  'pending' => PaymentStatus.pending,
  'held' => PaymentStatus.held,
  'failed' => PaymentStatus.failed,
  'refunded' => PaymentStatus.refunded,
  'partially_refunded' => PaymentStatus.partiallyRefunded,
  _ => PaymentStatus.unpaid,
};

PaymentMethod paymentMethodFromWire(Object? value) => switch (value) {
  'bank_transfer' => PaymentMethod.bankTransfer,
  'mobile_money' => PaymentMethod.mobileMoney,
  'ussd' => PaymentMethod.ussd,
  _ => PaymentMethod.card,
};

String paymentMethodToWire(PaymentMethod method) => switch (method) {
  PaymentMethod.card => 'card',
  PaymentMethod.bankTransfer => 'bank_transfer',
  PaymentMethod.mobileMoney => 'mobile_money',
  PaymentMethod.ussd => 'ussd',
};

ProofKind proofKindFromWire(Object? value) => switch (value) {
  'receipt' => ProofKind.receipt,
  'signature' => ProofKind.signature,
  _ => ProofKind.photo,
};

/// The wire `sos_status` enum is richer than the domain's (open, acknowledged,
/// dispatched, resolved, false_alarm): the three in-flight values all render
/// as "active" in the app; false_alarm reads as resolved.
SosStatus sosStatusFromWire(Object? value) => switch (value) {
  'resolved' || 'false_alarm' => SosStatus.resolved,
  _ => SosStatus.active,
};

/// A `payments` row. Column grants deliberately exclude `checkout_url` (it
/// comes from `get_payment_checkout`), so the entity never carries it.
/// `method` is nullable on the wire until start_payment fills it in; the safe
/// default renders as card.
Payment paymentFromRow(Map<String, dynamic> row) => Payment(
  id: SupabaseGateway.asId(row['id']),
  jobId: SupabaseGateway.asId(row['request_id']),
  amount: Money(
    SupabaseGateway.asMinorUnits(row['amount_minor']),
    row['currency'] as String? ?? 'NGN',
  ),
  method: paymentMethodFromWire(row['method']),
  status: paymentStatusFromWire(row['status']),
  createdAt: SupabaseGateway.asTimestamp(row['created_at']),
  gatewayReference: row['gateway_reference'] as String?,
  paidAt: row['confirmed_at'] == null
      ? null
      : SupabaseGateway.asTimestamp(row['confirmed_at']),
  expiresAt: row['expires_at'] == null
      ? null
      : SupabaseGateway.asTimestamp(row['expires_at']),
  failureReasonKey: row['failed_reason_key'] as String?,
);

/// A `proofs` row. `device_point` is the same GeoJSON shape as the request
/// points; the domain keeps lat/lng as plain doubles.
Proof proofFromRow(Map<String, dynamic> row) {
  final point = geoPointFromWire(row['device_point']);
  return Proof(
    id: SupabaseGateway.asId(row['id']),
    jobId: SupabaseGateway.asId(row['request_id']),
    providerId: SupabaseGateway.asId(row['uploaded_by']),
    kind: proofKindFromWire(row['kind']),
    storagePath: row['storage_path'] as String? ?? '',
    createdAt: SupabaseGateway.asTimestamp(row['server_received_at']),
    capturedAt: row['device_captured_at'] == null
        ? null
        : SupabaseGateway.asTimestamp(row['device_captured_at']),
    lat: point?.latitude,
    lng: point?.longitude,
  );
}

/// A `ratings` row (RLS scopes visibility to rater/ratee). `tags` are the
/// localization keys the rater picked.
Rating ratingFromRow(Map<String, dynamic> row) => Rating(
  id: SupabaseGateway.asId(row['id']),
  jobId: SupabaseGateway.asId(row['request_id']),
  raterId: SupabaseGateway.asId(row['rater_id']),
  rateeId: SupabaseGateway.asId(row['ratee_id']),
  stars: (row['stars'] as num?)?.toInt() ?? 0,
  tagKeys: (row['tags'] as List<dynamic>? ?? const <dynamic>[]).cast<String>(),
  comment: row['comment'] as String?,
  createdAt: SupabaseGateway.asTimestamp(row['created_at']),
);

/// An `sos_incidents` row. `request_id` is nullable on the wire (SOS can be
/// raised outside a job); the domain requires a job id, so a jobless alert
/// carries an empty one — the SOS UI only exists inside a job today.
SosAlert sosAlertFromRow(Map<String, dynamic> row) => SosAlert(
  id: SupabaseGateway.asId(row['id']),
  jobId: row['request_id'] as String? ?? '',
  triggeredBy: SupabaseGateway.asId(row['raised_by']),
  status: sosStatusFromWire(row['status']),
  createdAt: SupabaseGateway.asTimestamp(row['created_at']),
  location: geoPointFromWire(row['point']),
  trustedContactsNotified:
      (row['trusted_contacts_notified'] as num?)?.toInt() ?? 0,
);

/// The `verify_pin` jsonb result: `{verified, status, attempts_remaining}` —
/// a wrong PIN is a result, not an error (the attempt counter would roll back
/// with the exception otherwise). ERR_PIN_ATTEMPTS_EXCEEDED still raises.
PinVerificationResult pinVerificationFromWire(Object? value) {
  final map = value as Map<String, dynamic>;
  return PinVerificationResult(
    verified: map['verified'] as bool? ?? false,
    status: jobStatusFromWire(map['status']),
    attemptsRemaining: (map['attempts_remaining'] as num?)?.toInt() ?? 0,
  );
}

// ---------------------------------------------------------------------------
// M9.4: wallet, referrals, disputes.
// ---------------------------------------------------------------------------

DisputeStatus disputeStatusFromWire(Object? value) => switch (value) {
  'under_review' => DisputeStatus.inReview,
  'resolved' => DisputeStatus.resolved,
  'withdrawn' => DisputeStatus.withdrawn,
  // Unknown values render as open (still active) rather than closing a
  // dispute the user may still need to act on.
  _ => DisputeStatus.open,
};

/// A `disputes` row with the `requests(currency)` embed (the table itself
/// carries no currency, so the refund money needs the request's). Evidence
/// paths come from `dispute_evidence`, loaded separately.
Dispute disputeFromRow(
  Map<String, dynamic> row, {
  List<String> evidencePaths = const <String>[],
}) {
  final request = row['requests'];
  final currency = request is Map<String, dynamic>
      ? request['currency'] as String? ?? 'NGN'
      : 'NGN';
  return Dispute(
    id: SupabaseGateway.asId(row['id']),
    jobId: SupabaseGateway.asId(row['request_id']),
    openedBy: SupabaseGateway.asId(row['opened_by']),
    reasonKey: row['reason_code'] as String? ?? '',
    status: disputeStatusFromWire(row['status']),
    createdAt: SupabaseGateway.asTimestamp(row['created_at']),
    details: row['description'] as String?,
    evidencePaths: evidencePaths.isEmpty ? null : evidencePaths,
    slaDeadline: row['sla_due_at'] == null
        ? null
        : SupabaseGateway.asTimestamp(row['sla_due_at']),
    resolutionNoteKey: row['resolution_key'] as String?,
    refundAmount: moneyOrNull(row['refund_minor'], currency),
  );
}

/// A `withdrawals` row rendered as a wallet transaction. PROVISIONAL until
/// CR-20260923-03 lands a client-readable ledger: the private double-entry
/// ledger is deliberately not exposed, so withdrawals are the only real
/// wallet-history rows the contract offers today.
WalletTransaction withdrawalTransactionFromRow(
  Map<String, dynamic> row, {
  required WalletTransactionKind kind,
}) {
  final status = row['status'] as String? ?? 'requested';
  return WalletTransaction(
    id: SupabaseGateway.asId(row['id']),
    kind: kind,
    status: switch (status) {
      'paid' => WalletTransactionStatus.completed,
      'failed' || 'rejected' => WalletTransactionStatus.failed,
      _ => WalletTransactionStatus.pending,
    },
    amount: Money(
      SupabaseGateway.asMinorUnits(row['amount_minor']),
      row['currency'] as String? ?? 'NGN',
    ),
    createdAt: SupabaseGateway.asTimestamp(row['created_at']),
    descriptionKey: status == 'awaiting_approval'
        ? 'txnWithdrawalAwaitingApproval'
        : 'txnWithdrawal',
  );
}

/// Aggregates `my_referral_summary` rows (currency, status, commissions,
/// amount_minor) into the domain's totals: `available` is the withdrawable
/// balance, `holding` is everything not yet withdrawable (pending/earned/
/// holding), `earnedTotal` is the lifetime total excluding reversed
/// commissions. Statuses the client doesn't know yet count toward holding
/// rather than vanishing.
({Money earnedTotal, Money holding, Money available}) referralTotalsFromRows(
  List<Map<String, dynamic>> rows,
  String currency,
) {
  var available = 0;
  var holding = 0;
  for (final row in rows) {
    final amount = SupabaseGateway.asMinorUnits(row['amount_minor']);
    switch (row['status']) {
      case 'available':
        available += amount;
      case 'reversed':
        break;
      default:
        holding += amount;
    }
  }
  return (
    earnedTotal: Money(available + holding, currency),
    holding: Money(holding, currency),
    available: Money(available, currency),
  );
}

// ---------------------------------------------------------------------------
// M9.5: provider feed.
// ---------------------------------------------------------------------------

/// A `provider_feed` row. The feed deliberately exposes only approximate
/// coordinates and an area label (provider privacy of the customer's exact
/// pickup until assignment); the customer id is never in the payload.
JobRequest jobRequestFromFeedRow(Map<String, dynamic> row) {
  final currency = row['currency'] as String? ?? 'NGN';
  final isCustom = row['is_custom_category'] as bool? ?? false;
  GeoPoint? approxPoint(Object? lat, Object? lng) {
    final la = (lat as num?)?.toDouble();
    final lo = (lng as num?)?.toDouble();
    if (la == null || lo == null) return null;
    return GeoPoint(latitude: la, longitude: lo);
  }

  final hasDestination = row['has_destination'] as bool? ?? false;
  return JobRequest(
    id: SupabaseGateway.asId(row['request_id']),
    customerId: '',
    categoryId: isCustom
        ? 'custom'
        : (row['category_key'] as String? ?? 'custom'),
    isCustomCategory: isCustom,
    description: row['description'] as String? ?? '',
    mediaPaths: (row['media_paths'] as List<dynamic>? ?? const <dynamic>[])
        .cast<String>(),
    pickup: PlaceRef(
      label: row['pickup_area'] as String? ?? '',
      point: approxPoint(row['pickup_approx_lat'], row['pickup_approx_lng']),
    ),
    destination: hasDestination
        ? PlaceRef(
            label: '',
            point: approxPoint(
              row['destination_approx_lat'],
              row['destination_approx_lng'],
            ),
          )
        : null,
    urgency: urgencyFromWire(row['urgency']),
    status: JobStatus.published,
    createdAt: SupabaseGateway.asTimestamp(row['created_at']),
    scheduledAt: row['scheduled_at'] == null
        ? null
        : SupabaseGateway.asTimestamp(row['scheduled_at']),
    preferredPrice: moneyOrNull(row['preferred_price_minor'], currency),
    itemFloat: moneyOrNull(row['item_float_minor'], currency),
    expiresAt: row['expires_at'] == null
        ? null
        : SupabaseGateway.asTimestamp(row['expires_at']),
  );
}
