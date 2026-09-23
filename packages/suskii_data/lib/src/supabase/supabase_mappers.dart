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

// ---------------------------------------------------------------------------
// M9.6: chat + tracking.
// ---------------------------------------------------------------------------

ChatMessageType chatMessageTypeFromWire(Object? value) => switch (value) {
  'image' => ChatMessageType.image,
  'voice_note' => ChatMessageType.voiceNote,
  'location' => ChatMessageType.location,
  'offer_card' => ChatMessageType.offerCard,
  'system' => ChatMessageType.system,
  _ => ChatMessageType.text,
};

String chatMessageTypeToWire(ChatMessageType type) => switch (type) {
  ChatMessageType.text => 'text',
  ChatMessageType.image => 'image',
  ChatMessageType.voiceNote => 'voice_note',
  ChatMessageType.location => 'location',
  ChatMessageType.offerCard => 'offer_card',
  ChatMessageType.system => 'system',
};

/// A `messages` row. The job id comes from the `conversations(request_id)`
/// embed (messages key on conversation, not request). [readAt] is derived
/// from the OTHER participant's `message_reads` pointer — the wire has no
/// per-message read timestamp.
ChatMessage chatMessageFromRow(
  Map<String, dynamic> row, {
  String? jobId,
  DateTime? readAt,
}) {
  final conversation = row['conversations'];
  final embeddedJobId = conversation is Map<String, dynamic>
      ? conversation['request_id'] as String?
      : null;
  return ChatMessage(
    id: SupabaseGateway.asId(row['id']),
    jobId: embeddedJobId ?? jobId ?? '',
    senderId: SupabaseGateway.asId(row['sender_id']),
    type: chatMessageTypeFromWire(row['type']),
    createdAt: SupabaseGateway.asTimestamp(row['created_at']),
    text: row['body'] as String?,
    mediaPath: row['media_path'] as String?,
    offerId: row['offer_id'] as String?,
    location: geoPointFromWire(row['location']),
    readAt: readAt,
  );
}

// ---------------------------------------------------------------------------
// M9.7: support + settings.
// ---------------------------------------------------------------------------

SupportTicketStatus supportTicketStatusFromWire(Object? value) =>
    switch (value) {
      'waiting_on_user' => SupportTicketStatus.awaitingUser,
      'waiting_on_support' => SupportTicketStatus.awaitingSupport,
      'resolved' => SupportTicketStatus.resolved,
      'closed' => SupportTicketStatus.closed,
      _ => SupportTicketStatus.open,
    };

/// A `support_tickets` row. The wire has no subject field — the category
/// plays that role in the domain model. Messages are assembled by the
/// repository (batch-fetched from `ticket_messages` and grouped client-side).
SupportTicket supportTicketFromRow(
  Map<String, dynamic> row, {
  List<SupportMessage> messages = const <SupportMessage>[],
}) => SupportTicket(
  id: SupabaseGateway.asId(row['id']),
  subject: (row['category'] as String?) ?? '',
  status: supportTicketStatusFromWire(row['status']),
  createdAt: SupabaseGateway.asTimestamp(row['created_at']),
  messages: messages,
);

/// A `ticket_messages` row. `fromUser` is derived by comparing `author_id`
/// with the signed-in user's auth id. The wire marks AI triage on the ticket
/// (`ai_triage` jsonb), not per message, so [SupportMessage.aiTriage] is
/// always false here — see HANDOFF M9.7.
SupportMessage supportMessageFromRow(
  Map<String, dynamic> row, {
  required String myId,
}) => SupportMessage(
  id: SupabaseGateway.asId(row['id']),
  body: (row['body'] as String?) ?? '',
  fromUser: row['author_id'] == myId,
  createdAt: SupabaseGateway.asTimestamp(row['created_at']),
);

/// A `trusted_contacts` row. The phone number is stored encrypted
/// (`phone_ciphertext` + blind index) and never returned in plaintext, so the
/// domain `phoneE164` cannot be populated — tracked as CR-20260923-06.
TrustedContact trustedContactFromRow(Map<String, dynamic> row) =>
    TrustedContact(
      id: SupabaseGateway.asId(row['id']),
      name: (row['name'] as String?) ?? '',
      phoneE164: '',
    );

/// Postgres `time` column → minutes since midnight ('HH:MM:SS').
int? quietMinutesFromWire(Object? value) {
  if (value is! String) return null;
  final parts = value.split(':');
  if (parts.length < 2) return null;
  final hour = int.tryParse(parts[0]);
  final minute = int.tryParse(parts[1]);
  if (hour == null || minute == null) return null;
  return hour * 60 + minute;
}

/// Minutes since midnight → Postgres `time` literal ('HH:MM:SS').
String? quietMinutesToWire(int? minutes) {
  if (minutes == null) return null;
  final hour = (minutes ~/ 60).toString().padLeft(2, '0');
  final minute = (minutes % 60).toString().padLeft(2, '0');
  return '$hour:$minute:00';
}

/// Composes the flat domain preferences from `notification_preferences`
/// rows: push/sms/email read the (channel, 'transactional') rows, marketing
/// reads the ('push', 'marketing') row. Missing rows default to enabled
/// (matching the mock defaults); quiet hours come from any row that has them.
NotificationPreferences notificationPreferencesFromRows(
  List<Map<String, dynamic>> rows,
) {
  bool enabledFor(String channel, String category) {
    for (final row in rows) {
      if (row['channel'] == channel && row['category'] == category) {
        return row['enabled'] as bool? ?? true;
      }
    }
    return true;
  }

  int? quietStart;
  int? quietEnd;
  for (final row in rows) {
    quietStart ??= quietMinutesFromWire(row['quiet_start']);
    quietEnd ??= quietMinutesFromWire(row['quiet_end']);
  }

  return NotificationPreferences(
    push: enabledFor('push', 'transactional'),
    sms: enabledFor('sms', 'transactional'),
    email: enabledFor('email', 'transactional'),
    marketing: enabledFor('push', 'marketing'),
    quietStartMinutes: quietStart,
    quietEndMinutes: quietEnd,
  );
}

/// Explodes the flat domain preferences into `notification_preferences`
/// rows for upsert (PK: user_id, channel, category). The quiet window is
/// applied to every row.
List<Map<String, Object?>> notificationPreferenceRows(
  String userId,
  NotificationPreferences prefs,
) {
  final quietStart = quietMinutesToWire(prefs.quietStartMinutes);
  final quietEnd = quietMinutesToWire(prefs.quietEndMinutes);
  Map<String, Object?> row(String channel, String category, bool enabled) =>
      <String, Object?>{
        'user_id': userId,
        'channel': channel,
        'category': category,
        'enabled': enabled,
        'quiet_start': quietStart,
        'quiet_end': quietEnd,
      };
  return <Map<String, Object?>>[
    row('push', 'transactional', prefs.push),
    row('sms', 'transactional', prefs.sms),
    row('email', 'transactional', prefs.email),
    row('push', 'marketing', prefs.marketing),
  ];
}

// ---------------------------------------------------------------------------
// M9.8: KYC / verification.
// ---------------------------------------------------------------------------

KycStepKind kycStepKindFromWire(Object? value) => switch (value) {
  'customer_facial' => KycStepKind.customerFacial,
  'government_id' => KycStepKind.governmentId,
  'provider_facial' => KycStepKind.providerFacial,
  'id_document_capture' => KycStepKind.idDocumentCapture,
  'police_clearance' => KycStepKind.policeClearance,
  'address' => KycStepKind.address,
  'guarantor' => KycStepKind.guarantor,
  'payout_account' => KycStepKind.payoutAccount,
  'vehicle_documents' => KycStepKind.vehicleDocuments,
  'credentials' => KycStepKind.credentials,
  _ => KycStepKind.credentials,
};

String kycStepKindToWire(KycStepKind kind) => switch (kind) {
  KycStepKind.customerFacial => 'customer_facial',
  KycStepKind.governmentId => 'government_id',
  KycStepKind.providerFacial => 'provider_facial',
  KycStepKind.idDocumentCapture => 'id_document_capture',
  KycStepKind.policeClearance => 'police_clearance',
  KycStepKind.address => 'address',
  KycStepKind.guarantor => 'guarantor',
  KycStepKind.payoutAccount => 'payout_account',
  KycStepKind.vehicleDocuments => 'vehicle_documents',
  KycStepKind.credentials => 'credentials',
};

KycStepStatus kycStepStatusFromWire(Object? value) => switch (value) {
  'consent_pending' => KycStepStatus.consentPending,
  'in_progress' => KycStepStatus.inProgress,
  'in_review' => KycStepStatus.inReview,
  'verified' => KycStepStatus.verified,
  'rejected' => KycStepStatus.rejected,
  'expired' => KycStepStatus.expired,
  _ => KycStepStatus.notStarted,
};

VehicleType vehicleTypeFromWire(Object? value) => switch (value) {
  'bicycle' => VehicleType.bicycle,
  'motorcycle' => VehicleType.motorcycle,
  'tricycle' => VehicleType.tricycle,
  'car' => VehicleType.car,
  'van' => VehicleType.van,
  'truck' => VehicleType.truck,
  _ => VehicleType.walking,
};

String vehicleTypeToWire(VehicleType type) => switch (type) {
  VehicleType.walking => 'walking',
  VehicleType.bicycle => 'bicycle',
  VehicleType.motorcycle => 'motorcycle',
  VehicleType.tricycle => 'tricycle',
  VehicleType.car => 'car',
  VehicleType.van => 'van',
  VehicleType.truck => 'truck',
};

ProviderKind providerKindFromWire(Object? value) =>
    value == 'business' ? ProviderKind.business : ProviderKind.individual;

/// One row of `get_my_kyc_profile`. The wire carries no `submitted_at` /
/// `reviewed_at` (CR-20260923-10), so those stay null.
KycStep kycStepFromProfileRow(Map<String, dynamic> row) => KycStep(
  kind: kycStepKindFromWire(row['kind']),
  status: kycStepStatusFromWire(row['status']),
  attemptCount: (row['attempt_count'] as num?)?.toInt() ?? 0,
  rejectionReasonKey: row['rejection_reason_key'] as String?,
);

/// Display-only rollup replicating the mock's priority (rejected →
/// submitted → all-not-started → any-in-review → all-verified → in-progress).
/// The domain contract says this is server-computed; the wire has no rollup
/// yet (CR-20260923-10), and computing an authoritative status client-side
/// is forbidden — this only feeds the UI badge.
KycStepStatus kycOverallRollup(
  List<KycStep> steps, {
  DateTime? submittedForReviewAt,
}) {
  if (steps.any((s) => s.status == KycStepStatus.rejected)) {
    return KycStepStatus.rejected;
  }
  if (submittedForReviewAt != null) return KycStepStatus.inReview;
  if (steps.every((s) => s.status == KycStepStatus.notStarted)) {
    return KycStepStatus.notStarted;
  }
  if (steps.any((s) => s.status == KycStepStatus.inReview)) {
    return KycStepStatus.inReview;
  }
  if (steps.every((s) => s.status == KycStepStatus.verified)) {
    return KycStepStatus.verified;
  }
  return KycStepStatus.inProgress;
}
