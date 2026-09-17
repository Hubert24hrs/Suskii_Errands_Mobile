import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_data/suskii_data.dart';
import 'package:suskii_domain/suskii_domain.dart';
import 'package:test/test.dart';

void main() {
  late MockDatabase db;
  late MockBehavior behavior;

  setUp(() {
    db = MockDatabase();
    behavior = MockBehavior(
      latency: Duration.zero,
      kycReviewDelay: const Duration(milliseconds: 50),
    );
    // user-chidi is the unverified persona: no verification session, no KYC
    // profile, both verification levels unverified.
    behavior.currentUserId = 'user-chidi';
  });

  Matcher expectCode(String code) =>
      isA<AppError>().having((AppError e) => e.code, 'code', code);

  group('MockIdentityVerificationAdapter', () {
    test('liveness capture succeeds by default', () async {
      final adapter = MockIdentityVerificationAdapter(db, behavior);
      final session = await adapter.startLivenessSession();
      expect(session.sessionId, startsWith('liveness-'));
      final result = await adapter.captureLiveness(session.sessionId);
      expect(result.outcome, IdentityCheckOutcome.success);
      expect(result.reasonKey, isNull);
    });

    test(
      'failLiveness flag forces a failed outcome with a reason key',
      () async {
        behavior.failLiveness = true;
        final adapter = MockIdentityVerificationAdapter(db, behavior);
        final session = await adapter.startLivenessSession();
        final result = await adapter.captureLiveness(session.sessionId);
        expect(result.outcome, IdentityCheckOutcome.failed);
        expect(result.reasonKey, isNotNull);
      },
    );

    // Government-ID lookup is server-side only (review C.2): the adapter
    // exposes liveness capture, never a NIN → name lookup on device.
    test('ID lookup happens server-side via submitIdLookup', () async {
      final repo = MockVerificationRepository(db, behavior);
      final consented = await repo.giveBiometricConsent(
        idempotencyKey: newIdempotencyKey(),
      );
      final inReview = await repo.submitIdLookup(
        consented.id,
        'nin',
        '12345678901',
        idempotencyKey: newIdempotencyKey(),
      );
      expect(inReview.status, KycStepStatus.inReview);
      expect(inReview.rejectionReasonKey, isNull);
    });
  });

  group('MockVerificationRepository (customer facial flow)', () {
    test('facial start requires biometric consent', () async {
      final repo = MockVerificationRepository(db, behavior);
      expect(await repo.getCustomerVerification(), isNull);
      expect(
        () => repo.startFacialVerification(idempotencyKey: newIdempotencyKey()),
        throwsA(expectCode(ErrorCodes.consentRequired)),
      );
    });

    test(
      'happy path: consent → start → ID lookup → in-review → verified',
      () async {
        final repo = MockVerificationRepository(db, behavior);
        final consented = await repo.giveBiometricConsent(
          idempotencyKey: newIdempotencyKey(),
        );
        expect(consented.status, KycStepStatus.inProgress);
        expect(consented.kind, KycStepKind.customerFacial);

        final started = await repo.startFacialVerification(
          idempotencyKey: newIdempotencyKey(),
        );
        expect(started.status, KycStepStatus.inProgress);

        final inReview = await repo.submitIdLookup(
          started.id,
          'nin',
          '12345678901',
          idempotencyKey: newIdempotencyKey(),
        );
        expect(inReview.status, KycStepStatus.inReview);

        // Simulated review flips the session after kycReviewDelay.
        await Future<void>.delayed(const Duration(milliseconds: 150));
        final done = await repo.getCustomerVerification();
        expect(done!.status, KycStepStatus.verified);
        // The user record is upgraded too, so request creation unblocks.
        expect(
          db.users['user-chidi']!.customerVerification,
          VerificationStatus.verified,
        );
      },
    );

    test('watchCustomerVerification emits in-review then verified', () async {
      final repo = MockVerificationRepository(db, behavior);
      final statuses = repo
          .watchCustomerVerification()
          .map((VerificationSession? s) => s?.status)
          .take(4)
          .toList();
      final consented = await repo.giveBiometricConsent(
        idempotencyKey: newIdempotencyKey(),
      );
      await repo.submitIdLookup(
        consented.id,
        'nin',
        '12345678901',
        idempotencyKey: newIdempotencyKey(),
      );
      expect(await statuses, <KycStepStatus?>[
        null,
        KycStepStatus.inProgress,
        KycStepStatus.inReview,
        KycStepStatus.verified,
      ]);
    });

    test('ID lookup on a fresh session is an invalid step', () async {
      final repo = MockVerificationRepository(db, behavior);
      expect(
        () => repo.submitIdLookup(
          'vs-user-chidi',
          'nin',
          '12345678901',
          idempotencyKey: newIdempotencyKey(),
        ),
        throwsA(expectCode(ErrorCodes.kycStepInvalid)),
      );
    });
  });

  group('MockProviderKycRepository', () {
    test('fresh profile starts with every step not-started', () async {
      final repo = MockProviderKycRepository(db, behavior);
      final profile = await repo.getKycProfile();
      expect(profile.userId, 'user-chidi');
      expect(profile.overallStatus, KycStepStatus.notStarted);
      expect(
        profile.steps.every(
          (KycStep s) => s.status == KycStepStatus.notStarted,
        ),
        isTrue,
      );
      expect(profile.steps, isNot(contains(isNull)));
    });

    test('saveOnboarding stores kind, categories, areas and vehicle', () async {
      final repo = MockProviderKycRepository(db, behavior);
      final profile = await repo.saveOnboarding(
        const ProviderOnboardingInput(
          kind: ProviderKind.business,
          serviceCategoryIds: <String>['moving'],
          serviceAreaIds: <String>['lagos-lekki'],
          vehicleType: VehicleType.van,
          businessName: 'Chidi Logistics',
        ),
        idempotencyKey: newIdempotencyKey(),
      );
      expect(profile.kind, ProviderKind.business);
      expect(profile.serviceCategoryIds, <String>['moving']);
      expect(profile.vehicleType, VehicleType.van);
    });

    test('submitStep moves a step to in-review, then verified', () async {
      final repo = MockProviderKycRepository(db, behavior);
      final profile = await repo.submitStep(
        KycStepKind.guarantor,
        const GuarantorInput(
          fullName: 'Nnamdi Eze',
          phoneE164: '+2348011112222',
          relationship: 'brother',
        ),
        idempotencyKey: newIdempotencyKey(),
      );
      final step = profile.steps.singleWhere(
        (KycStep s) => s.kind == KycStepKind.guarantor,
      );
      expect(step.status, KycStepStatus.inReview);
      expect(step.attemptCount, 1);
      expect(profile.overallStatus, KycStepStatus.inReview);

      await Future<void>.delayed(const Duration(milliseconds: 150));
      final after = await repo.getKycProfile();
      expect(
        after.steps
            .singleWhere((KycStep s) => s.kind == KycStepKind.guarantor)
            .status,
        KycStepStatus.verified,
      );
    });

    test('wrong input type for a step is rejected', () async {
      final repo = MockProviderKycRepository(db, behavior);
      expect(
        () => repo.submitStep(
          KycStepKind.policeClearance,
          const GuarantorInput(
            fullName: 'Nnamdi Eze',
            phoneE164: '+2348011112222',
            relationship: 'brother',
          ),
          idempotencyKey: newIdempotencyKey(),
        ),
        throwsA(expectCode(ErrorCodes.kycStepInvalid)),
      );
    });

    test('resubmitting an in-review step is rejected', () async {
      final repo = MockProviderKycRepository(db, behavior);
      await repo.submitStep(
        KycStepKind.address,
        const AddressInput(
          line1: '12 Allen Ave',
          city: 'Ikeja',
          state: 'Lagos',
        ),
        idempotencyKey: newIdempotencyKey(),
      );
      expect(
        () => repo.submitStep(
          KycStepKind.address,
          const AddressInput(
            line1: '12 Allen Ave',
            city: 'Ikeja',
            state: 'Lagos',
          ),
          idempotencyKey: newIdempotencyKey(),
        ),
        throwsA(expectCode(ErrorCodes.kycStepInvalid)),
      );
    });

    test(
      'expired police clearance is rejected server-side with a reason key',
      () async {
        final repo = MockProviderKycRepository(db, behavior);
        final profile = await repo.submitStep(
          KycStepKind.policeClearance,
          PoliceClearanceInput(
            certificateNumber: 'PCC-2024-001',
            issueDate: DateTime.now().subtract(const Duration(days: 400)),
            expiryDate: DateTime.now().subtract(const Duration(days: 35)),
            uploadRef: 'mock://uploads/pcc.pdf',
          ),
          idempotencyKey: newIdempotencyKey(),
        );
        final step = profile.steps.singleWhere(
          (KycStep s) => s.kind == KycStepKind.policeClearance,
        );
        expect(step.status, KycStepStatus.rejected);
        expect(step.rejectionReasonKey, 'kycRejectPoliceClearanceExpired');
        expect(profile.overallStatus, KycStepStatus.rejected);
      },
    );

    test(
      'payout name match is a server result; 00-suffix mismatches',
      () async {
        final repo = MockProviderKycRepository(db, behavior);
        final match = await repo.resolvePayoutAccount(
          const PayoutAccountInput(
            bankCode: '058',
            accountNumber: '0123456789',
          ),
        );
        expect(match.nameMatch, isTrue);
        expect(match.resolvedName, 'Chidi Eze');
        expect(match.maskedAccountNumber, '••••6789');

        final mismatch = await repo.resolvePayoutAccount(
          const PayoutAccountInput(
            bankCode: '058',
            accountNumber: '0123456000',
          ),
        );
        expect(mismatch.nameMatch, isFalse);
        expect(mismatch.resolvedName, isNot('Chidi Eze'));
      },
    );

    test(
      'submitForReview throws while required steps are incomplete',
      () async {
        final repo = MockProviderKycRepository(db, behavior);
        expect(
          () => repo.submitForReview(idempotencyKey: newIdempotencyKey()),
          throwsA(expectCode(ErrorCodes.kycIncomplete)),
        );
      },
    );

    test(
      'submitForReview succeeds once required steps are in review',
      () async {
        final repo = MockProviderKycRepository(db, behavior);
        await repo.saveOnboarding(
          const ProviderOnboardingInput(
            kind: ProviderKind.individual,
            serviceCategoryIds: <String>['errands_delivery'],
            serviceAreaIds: <String>['lagos-ikeja'],
            vehicleType: VehicleType.walking,
          ),
          idempotencyKey: newIdempotencyKey(),
        );
        await repo.submitStep(
          KycStepKind.governmentId,
          const IdDocumentInput(idType: 'nin', idNumber: '12345678901'),
          idempotencyKey: newIdempotencyKey(),
        );
        await repo.submitStep(
          KycStepKind.providerFacial,
          'liveness-1',
          idempotencyKey: newIdempotencyKey(),
        );
        await repo.submitStep(
          KycStepKind.idDocumentCapture,
          const IdDocumentInput(
            idType: 'nin',
            idNumber: '12345678901',
            uploadRef: 'mock://uploads/id.jpg',
          ),
          idempotencyKey: newIdempotencyKey(),
        );
        await repo.submitStep(
          KycStepKind.policeClearance,
          PoliceClearanceInput(
            certificateNumber: 'PCC-2026-777',
            issueDate: DateTime.now().subtract(const Duration(days: 30)),
            expiryDate: DateTime.now().add(const Duration(days: 335)),
            uploadRef: 'mock://uploads/pcc.pdf',
          ),
          idempotencyKey: newIdempotencyKey(),
        );
        await repo.submitStep(
          KycStepKind.guarantor,
          const GuarantorInput(
            fullName: 'Nnamdi Eze',
            phoneE164: '+2348011112222',
            relationship: 'brother',
          ),
          idempotencyKey: newIdempotencyKey(),
        );
        await repo.submitStep(
          KycStepKind.payoutAccount,
          const PayoutAccountInput(
            bankCode: '058',
            accountNumber: '0123456789',
          ),
          idempotencyKey: newIdempotencyKey(),
        );
        final profile = await repo.submitForReview(
          idempotencyKey: newIdempotencyKey(),
        );
        expect(profile.overallStatus, KycStepStatus.inReview);
        expect(profile.submittedForReviewAt, isNotNull);
        expect(
          db.users['user-chidi']!.providerVerification,
          VerificationStatus.inReview,
        );
      },
    );

    test(
      'rejected-police-clearance persona cannot submit for review',
      () async {
        behavior.currentUserId = 'user-emeka';
        final repo = MockProviderKycRepository(db, behavior);
        final profile = await repo.getKycProfile();
        expect(profile.overallStatus, KycStepStatus.rejected);
        expect(
          profile.steps
              .singleWhere((KycStep s) => s.kind == KycStepKind.policeClearance)
              .rejectionReasonKey,
          'kycRejectPoliceClearanceExpired',
        );
        expect(
          () => repo.submitForReview(idempotencyKey: newIdempotencyKey()),
          throwsA(expectCode(ErrorCodes.kycIncomplete)),
        );
      },
    );
  });

  group('MockAuthRepository (M2 additions)', () {
    test('email OTP signs in with any 6-digit code', () async {
      final repo = MockAuthRepository(db, behavior);
      await repo.requestEmailOtp('chidi@example.com');
      final user = await repo.verifyEmailOtp('chidi@example.com', '482916');
      expect(user.id, 'user-chidi');
      expect(user.email, 'chidi@example.com');
      final state = await repo.authStateChanges().first;
      expect(state.status, AuthStatus.signedIn);
    });

    test('email OTP rejects malformed codes', () async {
      final repo = MockAuthRepository(db, behavior);
      expect(
        () => repo.verifyEmailOtp('chidi@example.com', '123'),
        throwsA(expectCode(ErrorCodes.otpInvalid)),
      );
    });

    test('social sign-in placeholders throw featureUnavailable', () async {
      final repo = MockAuthRepository(db, behavior);
      expect(
        repo.signInWithGoogle,
        throwsA(expectCode(ErrorCodes.featureUnavailable)),
      );
      expect(
        repo.signInWithApple,
        throwsA(expectCode(ErrorCodes.featureUnavailable)),
      );
    });
  });
}
