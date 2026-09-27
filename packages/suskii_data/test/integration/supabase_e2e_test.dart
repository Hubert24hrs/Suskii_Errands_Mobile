@Tags(<String>['integration'])
library;

import 'dart:io';

import 'package:supabase/supabase.dart';
import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_data/suskii_data.dart';
import 'package:suskii_domain/suskii_domain.dart';
import 'package:test/test.dart';

/// The app's own Supabase repositories against a real local stack
/// (`supabase start`): the same calls the screens make, end to end, with a
/// customer and a provider signed in as two real users.
///
/// Needs SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_KEY (the local
/// stack's; `supabase status -o env`). Skipped without them. The service key
/// plays only the parts no client can: creating the two users, marking the
/// provider verified (the KYC vendor's job), and confirming the payment (the
/// gateway's webhook).
void main() {
  final env = Platform.environment;
  final url = env['SUPABASE_URL'] ?? '';
  final anonKey = env['SUPABASE_ANON_KEY'] ?? '';
  final serviceKey = env['SUPABASE_SERVICE_KEY'] ?? '';
  final configured =
      url.isNotEmpty && anonKey.isNotEmpty && serviceKey.isNotEmpty;

  group('Supabase end to end', skip: configured ? false : 'no local stack', () {
    late SupabaseClient service;
    late SupabaseClient customerClient;
    late SupabaseClient providerClient;
    late SupabaseGateway customer;
    late SupabaseGateway provider;
    late String customerEmail;
    late String customerId;
    late String providerId;
    const password = 'e2e-Password-123!';
    final run = DateTime.now().microsecondsSinceEpoch;

    SupabaseClient client(String key) => SupabaseClient(
      url,
      key,
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );

    Future<String> createUser(String email, {required bool provider}) async {
      final created = await service.auth.admin.createUser(
        AdminUserAttributes(
          email: email,
          password: password,
          emailConfirm: true,
          userMetadata: <String, dynamic>{
            'country_code': 'NG',
            'language': 'en',
          },
        ),
      );
      final id = created.user!.id;
      // The KYC vendor's verdict: no client can set these.
      await service
          .from('profiles')
          .update(<String, dynamic>{
            'customer_verification': 'verified',
            if (provider) 'provider_verification': 'verified',
          })
          .eq('user_id', id);
      if (provider) {
        await service.from('provider_profiles').insert(<String, dynamic>{
          'user_id': id,
        });
      }
      return id;
    }

    setUpAll(() async {
      service = client(serviceKey);
      customerEmail = 'e2e-customer-$run@suskii.test';
      customerId = await createUser(customerEmail, provider: false);
      providerId = await createUser(
        'e2e-provider-$run@suskii.test',
        provider: true,
      );
      customerClient = client(anonKey);
      providerClient = client(anonKey);
      await providerClient.auth.signInWithPassword(
        email: 'e2e-provider-$run@suskii.test',
        password: password,
      );
      customer = SupabaseGateway(customerClient);
      provider = SupabaseGateway(providerClient);
    });

    tearDownAll(() async {
      await customerClient.dispose();
      await providerClient.dispose();
      await service.dispose();
    });

    test(
      'a first run bootstraps before anyone has signed in or chosen a country',
      () async {
        final anonymous = client(anonKey);
        addTearDown(anonymous.dispose);
        final boot = await SupabaseBootstrapRepository(
          SupabaseGateway(anonymous),
        ).getBootstrap();
        expect(boot.countryPack.countryCode, isNotEmpty);
        expect(boot.user, isNull);
      },
    );

    test(
      'email OTP signs the customer in, in the country they chose',
      () async {
        final link = await service.auth.admin.generateLink(
          type: GenerateLinkType.magiclink,
          email: customerEmail,
        );
        final user = await SupabaseAuthRepository(customer)
            .verifyEmailOtp(customerEmail, link.properties.emailOtp);
        expect(user.id, customerId);
        expect(user.countryCode, 'NG');
      },
    );

    test('the customer names themselves', () async {
      final user = await SupabaseUserRepository(customer)
          .updateDisplayName('  Ada E2E ');
      expect(user.displayName, 'Ada E2E');
      final boot = await SupabaseBootstrapRepository(customer)
          .getBootstrap(countryCode: 'KE');
      expect(boot.user?.displayName, 'Ada E2E');
      // A signed-in profile's country wins over the hint.
      expect(boot.countryPack.countryCode, 'NG');
    });

    late String requestId;
    late String offerId;

    test('request → offer → server ranking → accept', () async {
      final categories = await SupabaseCatalogRepository(customer)
          .getCategories();
      expect(categories, isNotEmpty);
      final requests = SupabaseRequestRepository(customer);
      final draft = await requests.createRequest(
        CreateRequestInput(
          categoryId: categories.first.id,
          description: 'E2E: collect a parcel',
          pickup: const PlaceRef(
            label: 'Yaba market',
            point: GeoPoint(latitude: 6.5095, longitude: 3.3711),
          ),
          preferredPrice: const Money(500000, 'NGN'),
        ),
        idempotencyKey: newIdempotencyKey(),
      );
      expect(draft.status, JobStatus.draft);
      final published = await requests.publishRequest(
        draft.id,
        idempotencyKey: newIdempotencyKey(),
      );
      expect(published.status, JobStatus.published);
      requestId = published.id;

      final offer = await SupabaseProviderRepository(provider).submitOffer(
        requestId: requestId,
        amount: const Money(450000, 'NGN'),
        idempotencyKey: newIdempotencyKey(),
      );
      offerId = offer.id;

      final ranked = await SupabaseOfferRepository(customer)
          .getRankedOffers(requestId);
      expect(ranked.map((r) => r.offerId), contains(offerId));

      final accepted = await SupabaseOfferRepository(customer)
          .acceptOffer(offerId, idempotencyKey: newIdempotencyKey());
      expect(accepted.status, OfferStatus.accepted);
    });

    test('payment is held, never marked paid by the client', () async {
      final session = await SupabasePaymentRepository(customer)
          .initializePayment(
            jobId: requestId,
            method: PaymentMethod.card,
            idempotencyKey: newIdempotencyKey(),
          );
      expect(session.payment.status, PaymentStatus.pending);

      // The gateway's part: record the checkout, then confirm from its webhook.
      final reference = 'e2e-ref-$run';
      await service.rpc<dynamic>(
        'gateway_record_checkout',
        params: <String, dynamic>{
          'p_payment_id': session.payment.id,
          'p_gateway': 'flutterwave',
          'p_gateway_reference': reference,
          'p_checkout_url': 'https://checkout.example/$reference',
        },
      );
      final status = await service.rpc<dynamic>(
        'gateway_confirm_payment',
        params: <String, dynamic>{
          'p_gateway': 'flutterwave',
          'p_gateway_reference': reference,
          'p_amount_minor': session.payment.amount.minorUnits,
          'p_fee_minor': 0,
        },
      );
      expect(status, isIn(<String>['paid_held', 'assigned']));

      final payment = await SupabasePaymentRepository(customer)
          .getPaymentForJob(requestId);
      expect(payment?.status, PaymentStatus.held);
    });

    test(
      'provider travels, the pickup PIN starts the work, SOS is raised',
      () async {
        final jobs = SupabaseJobProgressRepository(provider);
        await jobs.requestStatusChange(
          requestId,
          JobStatus.enRoute,
          idempotencyKey: newIdempotencyKey(),
        );
        // Outside the geofence with no reason is refused; at the pickup it is
        // not (the app sends the device's position, audit Y.29).
        await expectLater(
          jobs.requestStatusChange(
            requestId,
            JobStatus.arrived,
            idempotencyKey: newIdempotencyKey(),
            location: const GeoPoint(latitude: 6.60, longitude: 3.3711),
          ),
          throwsA(
            isA<AppError>().having(
              (e) => e.code,
              'code',
              ErrorCodes.notAtPickup,
            ),
          ),
        );
        await jobs.requestStatusChange(
          requestId,
          JobStatus.arrived,
          idempotencyKey: newIdempotencyKey(),
          location: const GeoPoint(latitude: 6.5096, longitude: 3.3712),
        );
        final pin = await SupabaseJobProgressRepository(customer)
            .revealHandoverPin(requestId, kind: HandoverPinKind.pickup);
        final verified = await jobs.verifyHandoverPin(
          requestId,
          pin,
          kind: HandoverPinKind.pickup,
          idempotencyKey: newIdempotencyKey(),
        );
        expect(verified.verified, isTrue);
        expect(verified.status, JobStatus.inProgress);

        final chat = await SupabaseChatRepository(customer).sendMessage(
          jobId: requestId,
          type: ChatMessageType.text,
          text: 'On my way down',
          idempotencyKey: newIdempotencyKey(),
        );
        expect(chat.text, 'On my way down');

        final sos = await SupabaseSafetyRepository(customer).triggerSos(
          jobId: requestId,
          idempotencyKey: newIdempotencyKey(),
          location: const GeoPoint(latitude: 6.51, longitude: 3.37),
        );
        expect(sos.id, isNotEmpty);
      },
    );

    test('proof must be uploaded before it counts', () async {
      final jobs = SupabaseJobProgressRepository(provider);
      await expectLater(
        jobs.submitProof(
          jobId: requestId,
          kind: ProofKind.photo,
          storagePath: '$requestId/never-uploaded.jpg',
          idempotencyKey: newIdempotencyKey(),
        ),
        throwsA(
          isA<AppError>().having(
            (e) => e.code,
            'code',
            ErrorCodes.uploadNotFound,
          ),
        ),
      );

      final path = await SupabaseMediaUploadRepository(provider).upload(
        bucket: UploadBucket.jobProofs,
        requestId: requestId,
        bytes: _jpeg,
        contentType: 'image/jpeg',
      );
      expect(path, startsWith('$requestId/'));
      await jobs.submitProof(
        jobId: requestId,
        kind: ProofKind.photo,
        storagePath: path,
        idempotencyKey: newIdempotencyKey(),
      );
      final done = await jobs.requestStatusChange(
        requestId,
        JobStatus.completedByProvider,
        idempotencyKey: newIdempotencyKey(),
      );
      expect(done.status, JobStatus.completedByProvider);
    });

    test('customer confirms and both sides rate', () async {
      final confirmed = await SupabaseJobProgressRepository(customer)
          .confirmCompletion(requestId, idempotencyKey: newIdempotencyKey());
      expect(confirmed.status, JobStatus.confirmed);
      final rating = await SupabaseRatingRepository(customer).submitRating(
        jobId: requestId,
        stars: 5,
        idempotencyKey: newIdempotencyKey(),
      );
      expect(rating.stars, 5);
      await SupabaseRatingRepository(provider).submitRating(
        jobId: requestId,
        stars: 4,
        idempotencyKey: newIdempotencyKey(),
      );
    });

    test('a dispute freezes the job', () async {
      final dispute = await SupabaseDisputeRepository(customer).openDispute(
        jobId: requestId,
        reasonKey: 'not_as_described',
        details: 'E2E dispute',
        idempotencyKey: newIdempotencyKey(),
      );
      expect(dispute.jobId, requestId);
      final job = await SupabaseRequestRepository(customer).getMyActiveJobs();
      expect(
        job.firstWhere((j) => j.id == requestId).status,
        JobStatus.disputed,
      );
    });

    test(
      'wallet, referrals and KYC upload answer for the signed-in user',
      () async {
        final wallet = await SupabaseWalletRepository(provider).getSummary();
        expect(wallet.available.currencyCode, 'NGN');
        final referral = await SupabaseReferralRepository(customer)
            .getSummary();
        expect(referral.code, isNotEmpty);
        final kycPath = await SupabaseMediaUploadRepository(provider).upload(
          bucket: UploadBucket.kycDocuments,
          bytes: _jpeg,
          contentType: 'image/jpeg',
        );
        expect(kycPath, startsWith('$providerId/'));
      },
    );

    test('data export, account deletion, and keeping the account', () async {
      final settings = SupabaseSettingsRepository(customer);
      final reference = await settings.requestDataExport(
        idempotencyKey: newIdempotencyKey(),
      );
      expect(reference, matches(RegExp(r'^EXP-[0-9A-F]{10}$')));

      final when = await settings.requestAccountDeletion(
        idempotencyKey: newIdempotencyKey(),
      );
      expect(when.isAfter(DateTime.now().toUtc()), isTrue);

      // Every session was revoked; signing back in shows the date.
      await customerClient.auth.signOut();
      await customerClient.auth.signInWithPassword(
        email: customerEmail,
        password: password,
      );
      final boot = await SupabaseBootstrapRepository(customer).getBootstrap();
      expect(boot.accountDeletionScheduledFor, isNotNull);

      expect(
        await settings.cancelAccountDeletion(
          idempotencyKey: newIdempotencyKey(),
        ),
        isTrue,
      );
      final after = await SupabaseBootstrapRepository(customer).getBootstrap();
      expect(after.accountDeletionScheduledFor, isNull);
    });
  });
}

/// The smallest valid JPEG: enough for Storage's content-type check.
final List<int> _jpeg = <int>[
  0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, //
  0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0xFF, 0xD9,
];
