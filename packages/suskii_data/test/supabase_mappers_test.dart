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
}
