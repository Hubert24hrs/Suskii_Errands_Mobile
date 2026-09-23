import 'package:suskii_data/suskii_data.dart';
import 'package:suskii_domain/suskii_domain.dart';
import 'package:test/test.dart';

/// M9.1: wire-row → domain mappings for the catalog/bootstrap slice. Pure
/// functions over the exact payload shapes in contracts v1 (get_bootstrap's
/// jsonb envelope comes from 20260916120700_auth_hooks_and_bootstrap.sql).
void main() {
  group('serviceCategoryFromRow', () {
    test('maps the row; id stays the KEY and proof zeros drop out', () {
      final category = serviceCategoryFromRow(<String, dynamic>{
        'id': '3f2a91c4-0000-4000-8000-000000000001',
        'key': 'document_delivery',
        'name_key': 'catDocumentDelivery',
        'icon_key': 'document',
        'allows_custom': false,
        'offer_ttl_seconds': 600,
        'max_counter_rounds': 5,
        'proof_requirements': <String, dynamic>{'photo': 1, 'receipt': 0},
      });
      expect(category.id, 'document_delivery');
      expect(category.labelKey, 'catDocumentDelivery');
      expect(category.proofRequirements, <String, int>{'photo': 1});
      expect(category.offerTtlSeconds, 600);
    });
  });

  group('priceBandFromRow', () {
    test('numeric minor units arrive as strings; basis maps', () {
      final band = priceBandFromRow(<String, dynamic>{
        'p25_minor': '150000',
        'p50_minor': '300000',
        'p75_minor': '500000',
        'currency': 'NGN',
        'sample_size': 214,
        'basis': 'history',
      });
      expect(band.p50, const Money(300000, 'NGN'));
      expect(band.sampleSize, 214);
      expect(band.basis, PriceBandBasis.history);
      expect(band.confidence, PriceBandConfidence.high);
    });

    test('rules basis + tiny sample reads as low confidence', () {
      final band = priceBandFromRow(<String, dynamic>{
        'p25_minor': 100000,
        'p50_minor': 200000,
        'p75_minor': 350000,
        'currency': 'UGX',
        'sample_size': 4,
        'basis': 'rules',
      });
      expect(band.basis, PriceBandBasis.rules);
      expect(band.confidence, PriceBandConfidence.low);
      expect(band.p75.currencyCode, 'UGX');
    });
  });

  group('countryPackFromBootstrap', () {
    test('maps the get_bootstrap country_pack envelope', () {
      final pack = countryPackFromBootstrap(
        <String, dynamic>{
          'code': 'NG',
          'status': 'live',
          'currency': <String, dynamic>{'code': 'NGN', 'exponent': 2},
          'calling_code': '234',
          'default_language': 'en',
          'supported_languages': <dynamic>['en', 'pcm'],
          'client': <String, dynamic>{
            'accepted_id_types': <dynamic>['nin'],
            'emergency_numbers': <dynamic>[
              <String, dynamic>{'label_key': 'sosPolice', 'number': '199'},
            ],
          },
        },
        launchCities: const <String>['Lagos', 'Abuja'],
      );
      expect(pack.countryCode, 'NG');
      expect(pack.status, CountryStatus.live);
      expect(pack.currencyCode, 'NGN');
      expect(pack.supportedLanguages, <String>['en', 'pcm']);
      expect(pack.launchCities, <String>['Lagos', 'Abuja']);
      expect(pack.emergencyNumbers.single.number, '199');
    });

    test('a client subset without extras falls back to spec defaults', () {
      final pack = countryPackFromBootstrap(<String, dynamic>{
        'code': 'KE',
        'status': 'beta',
        'currency': <String, dynamic>{'code': 'KES', 'exponent': 2},
      });
      expect(pack.status, CountryStatus.beta);
      expect(pack.emergencyNumbers, isEmpty);
      expect(pack.offerTtlSeconds, 600);
      expect(pack.maxNegotiationRounds, 5);
    });
  });

  group('appNotificationFromRow', () {
    test('wire keys map through; read comes from read_at', () {
      final notification = appNotificationFromRow(<String, dynamic>{
        'id': 9223372036854775807, // bigint beyond 2^53
        'kind': 'job_status',
        'title_key': 'notifJobStatusTitle',
        'body_key': 'notifJobStatusBody',
        'params': <String, dynamic>{'status': 'en_route'},
        'deep_link': '/customer/requests/abc',
        'read_at': null,
        'created_at': '2026-09-23T10:00:00.000Z',
      });
      expect(notification.id, '9223372036854775807');
      expect(notification.title, 'notifJobStatusTitle');
      expect(notification.read, isFalse);
      expect(notification.deeplink, '/customer/requests/abc');
    });
  });

  group('appUserFromProfileRow', () {
    test('bootstrap-shaped map (id, no created_at) still maps', () {
      final user = appUserFromProfileRow(<String, dynamic>{
        'id': '3f2a91c4-0000-4000-8000-0000000000aa',
        'display_name': 'Ada',
        'country_code': 'NG',
        'language': 'pcm',
        'active_mode': 'provider',
        'customer_verification': 'verified',
        'provider_verification': 'in_review',
        'trust_level': 'new',
      });
      expect(user.id, '3f2a91c4-0000-4000-8000-0000000000aa');
      expect(user.activeMode, UserMode.provider);
      expect(user.customerVerification, VerificationStatus.verified);
      expect(user.providerVerification, VerificationStatus.inReview);
      expect(user.trustLevel, TrustLevel.new_);
    });
  });

  requestMapperTests();
}

// ---------------------------------------------------------------------------
// M9.2: requests/offers rows (contracts v1: requests, jobs, offers,
// request_media, get_provider_card).
// ---------------------------------------------------------------------------

Map<String, dynamic> _requestRow() => <String, dynamic>{
  'id': 'req-uuid-1',
  'customer_id': 'cust-uuid-1',
  'is_custom_category': false,
  'custom_category_label': null,
  'description': 'Pick up my order',
  'urgency': 'urgent',
  'status': 'paid_held',
  'pickup_point': <String, dynamic>{
    'type': 'Point',
    'coordinates': <dynamic>[3.4219, 6.4281],
  },
  'pickup_label': 'Chicken Republic, Admiralty Way',
  'pickup_landmark_note': 'Blue gate',
  'destination_point': null,
  'destination_label': null,
  'destination_landmark_note': null,
  'scheduled_at': null,
  // numeric minor units arrive as strings (bigint/numeric columns).
  'preferred_price_minor': '300000',
  'item_float_minor': null,
  'declared_value_minor': null,
  'currency': 'NGN',
  'expires_at': '2026-09-23T14:00:00.000Z',
  'created_at': '2026-09-23T10:00:00.000Z',
  'service_categories': <String, dynamic>{'key': 'food_pickup'},
  'jobs': null,
};

Map<String, dynamic> _jobRow() => <String, dynamic>{
  'provider_id': 'prov-uuid-1',
  'agreed_amount_minor': '320000',
  'currency': 'NGN',
  'commission_rate_bps': 1250,
  'commission_minor': '40000',
  'net_minor': '280000',
  'estimated_gateway_fee_minor': '4800',
  'actual_gateway_fee_minor': null,
  'tip_minor': null,
};

void requestMapperTests() {
  group('jobRequestFromRow', () {
    test('maps a row with category embed and GeoJSON pickup point', () {
      final request = jobRequestFromRow(
        _requestRow(),
        mediaPaths: const <String>['req-uuid-1/photo.jpg'],
      );
      expect(request.id, 'req-uuid-1');
      expect(request.categoryId, 'food_pickup');
      expect(request.urgency, Urgency.urgent);
      expect(request.status, JobStatus.paidHeld);
      expect(request.pickup.label, 'Chicken Republic, Admiralty Way');
      expect(
        request.pickup.point,
        const GeoPoint(latitude: 6.4281, longitude: 3.4219),
      );
      expect(request.pickup.landmarkNote, 'Blue gate');
      expect(request.destination, isNull);
      expect(request.preferredPrice, const Money(300000, 'NGN'));
      expect(request.mediaPaths, <String>['req-uuid-1/photo.jpg']);
      expect(request.agreedPrice, isNull);
      expect(request.agreedBreakdown, isNull);
      expect(request.providerId, isNull);
      expect(request.expiresAt, DateTime.utc(2026, 9, 23, 14));
    });

    test('agreed money + breakdown come from the embedded jobs row', () {
      final row = _requestRow()..['jobs'] = _jobRow();
      final request = jobRequestFromRow(row);
      expect(request.agreedPrice, const Money(320000, 'NGN'));
      expect(request.providerId, 'prov-uuid-1');
      final breakdown = request.agreedBreakdown!;
      expect(breakdown.gross, const Money(320000, 'NGN'));
      expect(breakdown.platformCommission, const Money(40000, 'NGN'));
      expect(breakdown.net, const Money(280000, 'NGN'));
      expect(breakdown.providerPayout, const Money(280000, 'NGN'));
      expect(breakdown.commissionRateBps, 1250);
      expect(breakdown.estimatedGatewayFee, const Money(4800, 'NGN'));
      expect(breakdown.actualGatewayFee, isNull);
      expect(breakdown.tip, isNull);
    });

    test('jobs embed as single-element array (PostgREST variant) maps too', () {
      final row = _requestRow()..['jobs'] = <dynamic>[_jobRow()];
      expect(jobRequestFromRow(row).agreedPrice, const Money(320000, 'NGN'));
    });

    test('money null until the payment phase → no breakdown', () {
      final row = _requestRow()
        ..['jobs'] = (_jobRow()
          ..['commission_minor'] = null
          ..['net_minor'] = null);
      final request = jobRequestFromRow(row);
      // The job exists (agreed), but the commission is not computed yet.
      expect(request.agreedPrice, const Money(320000, 'NGN'));
      expect(request.agreedBreakdown, isNull);
    });

    test('custom category rows carry the key custom regardless of embed', () {
      final row = _requestRow()
        ..['is_custom_category'] = true
        ..['custom_category_label'] = 'Queue for me'
        ..['service_categories'] = null;
      final request = jobRequestFromRow(row);
      expect(request.isCustomCategory, isTrue);
      expect(request.categoryId, 'custom');
    });

    test('unknown status/urgency degrade to safe defaults', () {
      final row = _requestRow()
        ..['status'] = 'some_future_status'
        ..['urgency'] = 'some_future_urgency';
      final request = jobRequestFromRow(row);
      expect(request.status, JobStatus.cancelled);
      expect(request.status.isTerminal, isTrue);
      expect(request.urgency, Urgency.standard);
    });
  });

  group('offerFromRow', () {
    Map<String, dynamic> offerRow() => <String, dynamic>{
      'id': 'offer-uuid-1',
      'request_id': 'req-uuid-1',
      'provider_id': 'prov-uuid-1',
      'amount_minor': '350000',
      'currency': 'NGN',
      'message': 'Can do it now',
      'status': 'pending',
      'round': 2,
      'expires_at': '2026-09-23T10:10:00.000Z',
      'created_at': '2026-09-23T10:00:00.000Z',
    };

    test('maps the row with the provider card display fields', () {
      final offer = offerFromRow(
        offerRow(),
        card: <String, dynamic>{
          'display_name': 'Musa K.',
          'trust_level': 'trusted',
          'rating_avg_milli': 4250,
        },
      );
      expect(offer.id, 'offer-uuid-1');
      expect(offer.requestId, 'req-uuid-1');
      expect(offer.providerName, 'Musa K.');
      expect(offer.providerRating, 4.25);
      expect(offer.providerTrustLevel, TrustLevel.trusted);
      expect(offer.amount, const Money(350000, 'NGN'));
      expect(offer.status, OfferStatus.pending);
      expect(offer.round, 2);
      expect(offer.expiresAt, DateTime.utc(2026, 9, 23, 10, 10));
    });

    test('no card → blank name, zero rating, new trust level', () {
      final offer = offerFromRow(offerRow());
      expect(offer.providerName, '');
      expect(offer.providerRating, 0);
      expect(offer.providerTrustLevel, TrustLevel.new_);
    });

    test('unknown offer status degrades to expired (terminal)', () {
      final offer = offerFromRow(offerRow()..['status'] = 'some_future_status');
      expect(offer.status, OfferStatus.expired);
    });
  });
}
