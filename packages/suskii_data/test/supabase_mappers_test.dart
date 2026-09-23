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
  paymentProgressMapperTests();
  walletDisputeMapperTests();
  providerFeedMapperTests();
  chatMapperTests();
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

// ---------------------------------------------------------------------------
// M9.3: payments, proofs, ratings, SOS, PIN verification.
// ---------------------------------------------------------------------------

void paymentProgressMapperTests() {
  group('paymentFromRow', () {
    test('maps the row; method null on the wire defaults to card', () {
      final payment = paymentFromRow(<String, dynamic>{
        'id': 'pay-uuid-1',
        'request_id': 'req-uuid-1',
        'amount_minor': '320000',
        'currency': 'NGN',
        'method': null,
        'status': 'held',
        'gateway_reference': 'FLW-123',
        'confirmed_at': '2026-09-23T10:05:00.000Z',
        'expires_at': '2026-09-23T10:15:00.000Z',
        'failed_reason_key': null,
        'created_at': '2026-09-23T10:00:00.000Z',
      });
      expect(payment.amount, const Money(320000, 'NGN'));
      expect(payment.method, PaymentMethod.card);
      expect(payment.status, PaymentStatus.held);
      expect(payment.paidAt, DateTime.utc(2026, 9, 23, 10, 5));
      expect(payment.failureReasonKey, isNull);
    });

    test('failed payments carry the localizable reason key', () {
      final payment = paymentFromRow(<String, dynamic>{
        'id': 'pay-uuid-2',
        'request_id': 'req-uuid-1',
        'amount_minor': 320000,
        'currency': 'NGN',
        'method': 'bank_transfer',
        'status': 'failed',
        'failed_reason_key': 'paymentDeclined',
        'created_at': '2026-09-23T10:00:00.000Z',
      });
      expect(payment.method, PaymentMethod.bankTransfer);
      expect(payment.status, PaymentStatus.failed);
      expect(payment.failureReasonKey, 'paymentDeclined');
      expect(payment.paidAt, isNull);
    });
  });

  group('proofFromRow', () {
    test('device_point GeoJSON maps to lat/lng doubles', () {
      final proof = proofFromRow(<String, dynamic>{
        'id': 'proof-uuid-1',
        'request_id': 'req-uuid-1',
        'uploaded_by': 'prov-uuid-1',
        'kind': 'receipt',
        'storage_path': 'req-uuid-1/receipt.jpg',
        'device_point': <String, dynamic>{
          'type': 'Point',
          'coordinates': <dynamic>[3.4219, 6.4281],
        },
        'device_captured_at': '2026-09-23T09:58:00.000Z',
        'server_received_at': '2026-09-23T10:00:00.000Z',
      });
      expect(proof.kind, ProofKind.receipt);
      expect(proof.providerId, 'prov-uuid-1');
      expect(proof.lat, 6.4281);
      expect(proof.lng, 3.4219);
      expect(proof.capturedAt, DateTime.utc(2026, 9, 23, 9, 58));
      expect(proof.createdAt, DateTime.utc(2026, 9, 23, 10));
    });

    test('missing device data maps to nulls', () {
      final proof = proofFromRow(<String, dynamic>{
        'id': 'proof-uuid-2',
        'request_id': 'req-uuid-1',
        'uploaded_by': 'prov-uuid-1',
        'kind': 'photo',
        'storage_path': 'req-uuid-1/photo.jpg',
        'device_point': null,
        'device_captured_at': null,
        'server_received_at': '2026-09-23T10:00:00.000Z',
      });
      expect(proof.lat, isNull);
      expect(proof.lng, isNull);
      expect(proof.capturedAt, isNull);
    });
  });

  group('ratingFromRow', () {
    test('tags map through as localization keys', () {
      final rating = ratingFromRow(<String, dynamic>{
        'id': 'rating-uuid-1',
        'request_id': 'req-uuid-1',
        'rater_id': 'cust-uuid-1',
        'ratee_id': 'prov-uuid-1',
        'stars': 5,
        'tags': <dynamic>['ratingTagPunctual', 'ratingTagProfessional'],
        'comment': 'Great',
        'created_at': '2026-09-23T12:00:00.000Z',
      });
      expect(rating.stars, 5);
      expect(rating.tagKeys, <String>[
        'ratingTagPunctual',
        'ratingTagProfessional',
      ]);
    });
  });

  group('sosAlertFromRow', () {
    test('the three in-flight wire statuses all read as active', () {
      for (final wire in <String>['open', 'acknowledged', 'dispatched']) {
        final alert = sosAlertFromRow(<String, dynamic>{
          'id': 'sos-uuid-1',
          'request_id': 'req-uuid-1',
          'raised_by': 'cust-uuid-1',
          'status': wire,
          'point': null,
          'trusted_contacts_notified': 2,
          'created_at': '2026-09-23T11:00:00.000Z',
        });
        expect(alert.status, SosStatus.active, reason: wire);
        expect(alert.trustedContactsNotified, 2);
      }
    });

    test('resolved and false_alarm read as resolved; jobless alerts get an empty job id', () {
      for (final wire in <String>['resolved', 'false_alarm']) {
        final alert = sosAlertFromRow(<String, dynamic>{
          'id': 'sos-uuid-2',
          'request_id': null,
          'raised_by': 'cust-uuid-1',
          'status': wire,
          'point': null,
          'trusted_contacts_notified': 0,
          'created_at': '2026-09-23T11:00:00.000Z',
        });
        expect(alert.status, SosStatus.resolved, reason: wire);
        expect(alert.jobId, '');
      }
    });
  });

  group('pinVerificationFromWire', () {
    test('wrong PIN is a result, not an error', () {
      final result = pinVerificationFromWire(<String, dynamic>{
        'verified': false,
        'status': 'arrived',
        'attempts_remaining': 4,
      });
      expect(result.verified, isFalse);
      expect(result.status, JobStatus.arrived);
      expect(result.attemptsRemaining, 4);
    });

    test('a verified pickup PIN reports the in_progress transition', () {
      final result = pinVerificationFromWire(<String, dynamic>{
        'verified': true,
        'status': 'in_progress',
        'attempts_remaining': 5,
      });
      expect(result.verified, isTrue);
      expect(result.status, JobStatus.inProgress);
    });
  });
}

// ---------------------------------------------------------------------------
// M9.4: disputes, withdrawals, referral totals.
// ---------------------------------------------------------------------------

void walletDisputeMapperTests() {
  group('disputeFromRow', () {
    Map<String, dynamic> disputeRow() => <String, dynamic>{
      'id': 'disp-uuid-1',
      'request_id': 'req-uuid-1',
      'opened_by': 'cust-uuid-1',
      'reason_code': 'disputeReasonItemNotDelivered',
      'description': 'Package never arrived',
      'status': 'under_review',
      'sla_due_at': '2026-09-25T10:00:00.000Z',
      'resolution_key': null,
      'refund_minor': null,
      'created_at': '2026-09-23T12:00:00.000Z',
      'requests': <String, dynamic>{'currency': 'NGN'},
    };

    test('maps the row; refund money uses the embedded request currency', () {
      final dispute = disputeFromRow(
        disputeRow()
          ..['refund_minor'] = '160000'
          ..['status'] = 'resolved'
          ..['resolution_key'] = 'disputeResolvedPartialRefund',
        evidencePaths: const <String>['disp-uuid-1/photo.jpg'],
      );
      expect(dispute.id, 'disp-uuid-1');
      expect(dispute.jobId, 'req-uuid-1');
      expect(dispute.reasonKey, 'disputeReasonItemNotDelivered');
      expect(dispute.status, DisputeStatus.resolved);
      expect(dispute.resolutionNoteKey, 'disputeResolvedPartialRefund');
      expect(dispute.refundAmount, const Money(160000, 'NGN'));
      expect(dispute.evidencePaths, <String>['disp-uuid-1/photo.jpg']);
      expect(dispute.slaDeadline, DateTime.utc(2026, 9, 25, 10));
    });

    test(
      'wire statuses fold: under_review → inReview, withdrawn stays distinct',
      () {
        expect(
          disputeFromRow(disputeRow()..['status'] = 'under_review').status,
          DisputeStatus.inReview,
        );
        expect(
          disputeFromRow(disputeRow()..['status'] = 'withdrawn').status,
          DisputeStatus.withdrawn,
        );
        // Unknown stays open (still active) rather than closing the dispute.
        expect(
          disputeFromRow(disputeRow()..['status'] = 'some_future_status')
              .status,
          DisputeStatus.open,
        );
      },
    );

    test('no embed and no refund → currency fallback, refund null', () {
      final row = disputeRow()..['requests'] = null;
      final dispute = disputeFromRow(row);
      expect(dispute.refundAmount, isNull);
      expect(dispute.evidencePaths, isNull);
    });
  });

  group('withdrawalTransactionFromRow', () {
    test('paid maps completed; awaiting_approval gets its label key', () {
      final paid = withdrawalTransactionFromRow(<String, dynamic>{
        'id': 'wd-1',
        'amount_minor': '500000',
        'currency': 'NGN',
        'status': 'paid',
        'created_at': '2026-09-23T12:00:00.000Z',
      }, kind: WalletTransactionKind.payout);
      expect(paid.status, WalletTransactionStatus.completed);
      expect(paid.descriptionKey, 'txnWithdrawal');

      final awaiting = withdrawalTransactionFromRow(<String, dynamic>{
        'id': 'wd-2',
        'amount_minor': 700000,
        'currency': 'NGN',
        'status': 'awaiting_approval',
        'created_at': '2026-09-23T12:00:00.000Z',
      }, kind: WalletTransactionKind.referral);
      expect(awaiting.status, WalletTransactionStatus.pending);
      expect(awaiting.descriptionKey, 'txnWithdrawalAwaitingApproval');
      expect(awaiting.kind, WalletTransactionKind.referral);
      expect(awaiting.amount, const Money(700000, 'NGN'));
    });

    test('failed and rejected both read as failed', () {
      for (final wire in <String>['failed', 'rejected']) {
        final txn = withdrawalTransactionFromRow(<String, dynamic>{
          'id': 'wd-3',
          'amount_minor': 1000,
          'currency': 'NGN',
          'status': wire,
          'created_at': '2026-09-23T12:00:00.000Z',
        }, kind: WalletTransactionKind.payout);
        expect(txn.status, WalletTransactionStatus.failed, reason: wire);
      }
    });
  });

  group('referralTotalsFromRows', () {
    test('available is withdrawable; everything else counts as holding', () {
      final totals = referralTotalsFromRows(<Map<String, dynamic>>[
        <String, dynamic>{'status': 'available', 'amount_minor': '50000'},
        <String, dynamic>{'status': 'holding', 'amount_minor': 20000},
        <String, dynamic>{'status': 'pending', 'amount_minor': 10000},
        <String, dynamic>{'status': 'reversed', 'amount_minor': 5000},
        // Unknown statuses count toward holding rather than vanishing.
        <String, dynamic>{'status': 'some_future_status', 'amount_minor': 1},
      ], 'NGN');
      expect(totals.available, const Money(50000, 'NGN'));
      expect(totals.holding, const Money(30001, 'NGN'));
      expect(totals.earnedTotal, const Money(80001, 'NGN'));
    });

    test('empty rows zero out in the requested currency', () {
      final totals = referralTotalsFromRows(
        const <Map<String, dynamic>>[],
        'KES',
      );
      expect(totals.available, const Money(0, 'KES'));
      expect(totals.holding, const Money(0, 'KES'));
      expect(totals.earnedTotal, const Money(0, 'KES'));
    });
  });
}

// ---------------------------------------------------------------------------
// M9.5: provider feed.
// ---------------------------------------------------------------------------

void providerFeedMapperTests() {
  group('jobRequestFromFeedRow', () {
    test('maps the feed row with approximate coordinates only', () {
      final request = jobRequestFromFeedRow(<String, dynamic>{
        'request_id': 'req-uuid-9',
        'category_key': 'food_pickup',
        'is_custom_category': false,
        'custom_category_label': null,
        'description': 'Pick up my order',
        'urgency': 'urgent',
        'pickup_area': 'Lekki Phase 1',
        'pickup_approx_lat': 6.44,
        'pickup_approx_lng': 3.47,
        'has_destination': true,
        'destination_approx_lat': 6.45,
        'destination_approx_lng': 3.43,
        'distance_m': 1200,
        'media_paths': <dynamic>['req-uuid-9/photo.jpg'],
        'scheduled_at': null,
        'preferred_price_minor': '300000',
        'item_float_minor': null,
        'currency': 'NGN',
        'created_at': '2026-09-23T10:00:00.000Z',
        'expires_at': '2026-09-23T14:00:00.000Z',
        'already_offered': false,
      });
      expect(request.id, 'req-uuid-9');
      // The feed never exposes the customer id.
      expect(request.customerId, '');
      expect(request.categoryId, 'food_pickup');
      expect(request.status, JobStatus.published);
      expect(request.pickup.label, 'Lekki Phase 1');
      expect(
        request.pickup.point,
        const GeoPoint(latitude: 6.44, longitude: 3.47),
      );
      expect(request.destination, isNotNull);
      expect(request.destination!.point!.latitude, 6.45);
      expect(request.preferredPrice, const Money(300000, 'NGN'));
      expect(request.mediaPaths, <String>['req-uuid-9/photo.jpg']);
      expect(request.agreedPrice, isNull);
    });

    test('no destination and no approx point → nulls, not fake zeros', () {
      final request = jobRequestFromFeedRow(<String, dynamic>{
        'request_id': 'req-uuid-10',
        'category_key': null,
        'is_custom_category': true,
        'custom_category_label': 'Queue for me',
        'description': 'Queue at the bank',
        'urgency': 'standard',
        'pickup_area': 'Ikoyi',
        'pickup_approx_lat': null,
        'pickup_approx_lng': null,
        'has_destination': false,
        'media_paths': <dynamic>[],
        'currency': 'NGN',
        'created_at': '2026-09-23T10:00:00.000Z',
      });
      expect(request.isCustomCategory, isTrue);
      expect(request.categoryId, 'custom');
      expect(request.destination, isNull);
      expect(request.pickup.point, isNull);
      expect(request.preferredPrice, isNull);
    });
  });
}

// ---------------------------------------------------------------------------
// M9.6: chat.
// ---------------------------------------------------------------------------

void chatMapperTests() {
  group('chatMessageFromRow', () {
    test('maps the row; job id comes from the conversations embed', () {
      final message = chatMessageFromRow(<String, dynamic>{
        'id': 9223372036854775807, // bigint beyond 2^53
        'sender_id': 'cust-uuid-1',
        'type': 'location',
        'body': null,
        'media_path': null,
        'offer_id': null,
        'location': <String, dynamic>{
          'type': 'Point',
          'coordinates': <dynamic>[3.4219, 6.4281],
        },
        'created_at': '2026-09-23T10:00:00.000Z',
        'conversations': <String, dynamic>{'request_id': 'req-uuid-1'},
      }, readAt: DateTime.utc(2026, 9, 23, 10, 5));
      expect(message.id, '9223372036854775807');
      expect(message.jobId, 'req-uuid-1');
      expect(message.type, ChatMessageType.location);
      expect(
        message.location,
        const GeoPoint(latitude: 6.4281, longitude: 3.4219),
      );
      expect(message.readAt, DateTime.utc(2026, 9, 23, 10, 5));
    });

    test('without the embed the explicit job id wins; unknown type → text', () {
      final message = chatMessageFromRow(<String, dynamic>{
        'id': 1,
        'sender_id': 'prov-uuid-1',
        'type': 'some_future_type',
        'body': 'On my way',
        'created_at': '2026-09-23T10:00:00.000Z',
      }, jobId: 'req-uuid-2');
      expect(message.jobId, 'req-uuid-2');
      expect(message.type, ChatMessageType.text);
      expect(message.text, 'On my way');
      expect(message.readAt, isNull);
    });

    test('wire names round-trip (voiceNote/offerCard are snake_case)', () {
      expect(chatMessageTypeToWire(ChatMessageType.voiceNote), 'voice_note');
      expect(chatMessageTypeToWire(ChatMessageType.offerCard), 'offer_card');
      expect(chatMessageTypeFromWire('voice_note'), ChatMessageType.voiceNote);
      expect(chatMessageTypeFromWire('offer_card'), ChatMessageType.offerCard);
    });
  });
}
