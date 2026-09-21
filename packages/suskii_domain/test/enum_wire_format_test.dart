import 'dart:convert';

import 'package:suskii_domain/suskii_domain.dart';
import 'package:test/test.dart';

/// Golden tests for the enum wire format (review N.6): Dart camelCase enums
/// serialize as lower snake_case — the same values Postgres and the
/// Supabase-generated contract types use. Contracts v1 builds on these.
void main() {
  final now = DateTime.utc(2026, 9, 24);

  group('enum wire values are snake_case', () {
    test('JobStatus', () {
      JobRequest withStatus(JobStatus s) => JobRequest(
        id: 'r1',
        customerId: 'u1',
        categoryId: 'custom',
        isCustomCategory: true,
        description: 'd',
        mediaPaths: const [],
        pickup: const PlaceRef(label: 'x'),
        urgency: Urgency.standard,
        status: s,
        createdAt: now,
      );
      expect(
        withStatus(JobStatus.offersReceived).toJson()['status'],
        'offers_received',
      );
      expect(
        withStatus(JobStatus.paymentPending).toJson()['status'],
        'payment_pending',
      );
      expect(withStatus(JobStatus.paidHeld).toJson()['status'], 'paid_held');
      expect(withStatus(JobStatus.enRoute).toJson()['status'], 'en_route');
      expect(
        withStatus(JobStatus.inProgress).toJson()['status'],
        'in_progress',
      );
      expect(
        withStatus(JobStatus.completedByProvider).toJson()['status'],
        'completed_by_provider',
      );
      expect(
        withStatus(JobStatus.settlementPending).toJson()['status'],
        'settlement_pending',
      );
      // Round-trip back from wire values (through real JSON encoding).
      final wire = jsonDecode(
        jsonEncode(withStatus(JobStatus.offersReceived)),
      ) as Map<String, dynamic>;
      expect(JobRequest.fromJson(wire).status, JobStatus.offersReceived);
    });

    test('Urgency', () {
      final r = JobRequest(
        id: 'r1',
        customerId: 'u1',
        categoryId: 'custom',
        isCustomCategory: true,
        description: 'd',
        mediaPaths: const [],
        pickup: const PlaceRef(label: 'x'),
        urgency: Urgency.emergency,
        status: JobStatus.draft,
        createdAt: now,
      );
      expect(r.toJson()['urgency'], 'emergency');
    });

    test('OfferStatus + TrustLevel', () {
      Offer withStatus(OfferStatus s) => Offer(
        id: 'o1',
        requestId: 'r1',
        providerId: 'p1',
        providerName: 'P',
        providerRating: 4.5,
        providerTrustLevel: TrustLevel.new_,
        amount: const Money(100, 'NGN'),
        status: s,
        round: 1,
        createdAt: now,
      );
      expect(withStatus(OfferStatus.pending).toJson()['status'], 'pending');
      expect(withStatus(OfferStatus.declined).toJson()['status'], 'declined');
      expect(withStatus(OfferStatus.withdrawn).toJson()['status'], 'withdrawn');
      expect(
        withStatus(OfferStatus.pending).toJson()['providerTrustLevel'],
        'new',
      );
    });

    test('UserMode + VerificationStatus', () {
      AppUser withVerification(VerificationStatus v) => AppUser(
        id: 'u1',
        displayName: 'U',
        countryCode: 'NG',
        preferredLanguage: 'en',
        activeMode: UserMode.provider,
        customerVerification: v,
        providerVerification: VerificationStatus.inReview,
        trustLevel: TrustLevel.verified,
        createdAt: now,
      );
      expect(
        withVerification(VerificationStatus.unverified).toJson()['activeMode'],
        'provider',
      );
      expect(
        withVerification(VerificationStatus.unverified)
            .toJson()['customerVerification'],
        'unverified',
      );
      expect(
        withVerification(VerificationStatus.unverified)
            .toJson()['providerVerification'],
        'in_review',
      );
    });

    test('ChatMessageType', () {
      ChatMessage withType(ChatMessageType t) => ChatMessage(
        id: 'm1',
        jobId: 'r1',
        senderId: 'u1',
        type: t,
        createdAt: now,
      );
      expect(
        withType(ChatMessageType.voiceNote).toJson()['type'],
        'voice_note',
      );
      expect(
        withType(ChatMessageType.offerCard).toJson()['type'],
        'offer_card',
      );
    });

    test('Wallet enums', () {
      WalletTransaction withKind(WalletTransactionKind k) => WalletTransaction(
        id: 't1',
        kind: k,
        status: WalletTransactionStatus.completed,
        amount: const Money(1, 'NGN'),
        createdAt: now,
      );
      expect(
        withKind(WalletTransactionKind.itemFloat).toJson()['kind'],
        'item_float',
      );
      expect(
        withKind(WalletTransactionKind.payout).toJson()['status'],
        'completed',
      );
    });

    test('CountryStatus', () {
      const pack = CountryPack(
        countryCode: 'KE',
        status: CountryStatus.beta,
        currencyCode: 'KES',
        supportedLanguages: ['en'],
        defaultLanguage: 'en',
        launchCities: ['Nairobi'],
        emergencyNumbers: [],
        offerTtlSeconds: 600,
        maxNegotiationRounds: 5,
      );
      expect(pack.toJson()['status'], 'beta');
    });

    test('KycStepKind + KycStepStatus', () {
      KycStep withKind(KycStepKind k, KycStepStatus s) =>
          KycStep(kind: k, status: s, attemptCount: 0);
      expect(
        withKind(
          KycStepKind.policeClearance,
          KycStepStatus.notStarted,
        ).toJson()['kind'],
        'police_clearance',
      );
      expect(
        withKind(
          KycStepKind.payoutAccount,
          KycStepStatus.consentPending,
        ).toJson()['status'],
        'consent_pending',
      );
      expect(
        withKind(
          KycStepKind.vehicleDocuments,
          KycStepStatus.inReview,
        ).toJson()['status'],
        'in_review',
      );
    });

    test('ProviderKind + VehicleType', () {
      const profile = ProviderKycProfile(
        userId: 'u1',
        kind: ProviderKind.business,
        serviceCategoryIds: [],
        serviceAreaIds: [],
        steps: [],
        overallStatus: KycStepStatus.notStarted,
        vehicleType: VehicleType.motorcycle,
      );
      expect(profile.toJson()['kind'], 'business');
      expect(profile.toJson()['vehicleType'], 'motorcycle');
    });

    test('PriceBandConfidence + PriceBandBasis + ConciergeRole', () {
      const band = PriceBand(
        p25: Money(1, 'NGN'),
        p50: Money(2, 'NGN'),
        p75: Money(3, 'NGN'),
        sampleSize: 10,
        confidence: PriceBandConfidence.medium,
        basis: PriceBandBasis.rules,
      );
      expect(band.toJson()['confidence'], 'medium');
      expect(band.toJson()['basis'], 'rules');
      final msg = ConciergeMessage(
        id: 'c1',
        conversationId: 'conv1',
        role: ConciergeRole.assistant,
        text: 'hi',
        createdAt: now,
      );
      expect(msg.toJson()['role'], 'assistant');
    });

    test('M4 enums: PaymentMethod + PaymentStatus + SosStatus', () {
      Payment withMethod(PaymentMethod m, PaymentStatus s) => Payment(
        id: 'p1',
        jobId: 'r1',
        amount: const Money(100, 'NGN'),
        method: m,
        status: s,
        createdAt: now,
      );
      expect(
        withMethod(
          PaymentMethod.bankTransfer,
          PaymentStatus.held,
        ).toJson()['method'],
        'bank_transfer',
      );
      expect(
        withMethod(
          PaymentMethod.mobileMoney,
          PaymentStatus.pending,
        ).toJson()['method'],
        'mobile_money',
      );
      expect(
        withMethod(
          PaymentMethod.ussd,
          PaymentStatus.partiallyRefunded,
        ).toJson()['status'],
        'partially_refunded',
      );
      final alert = SosAlert(
        id: 's1',
        jobId: 'r1',
        triggeredBy: 'u1',
        status: SosStatus.active,
        createdAt: now,
      );
      expect(alert.toJson()['status'], 'active');
      final rating = Rating(
        id: 'rt1',
        jobId: 'r1',
        raterId: 'u1',
        rateeId: 'u2',
        stars: 5,
        tagKeys: const ['ratingTagPunctual'],
        createdAt: now,
      );
      expect(Rating.fromJson(rating.toJson()).stars, 5);
    });
  });
}
