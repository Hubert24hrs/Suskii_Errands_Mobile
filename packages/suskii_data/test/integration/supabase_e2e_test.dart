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

    Future<String> createUser(
      String email, {
      required bool provider,
      String? phone,
    }) async {
      final created = await service.auth.admin.createUser(
        AdminUserAttributes(
          email: email,
          phone: phone,
          phoneConfirm: phone != null,
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
      'the trip is shared as a real link that a stranger can follow',
      () async {
        // The share base is per environment (RB-08); this stack sets one.
        const base = 'http://localhost:3000/t/';
        await service
            .from('remote_config')
            .update(<String, dynamic>{'value': base})
            .eq('key', 'trip_share_base_url');
        final share = await SupabaseSafetyRepository(
          customer,
        ).createTripShareLink(requestId, idempotencyKey: newIdempotencyKey());
        expect(share.url, startsWith(base));
        expect(share.expiresAt.isAfter(DateTime.now()), isTrue);

        final stranger = client(anonKey);
        addTearDown(stranger.dispose);
        final rows = await stranger.rpc<dynamic>(
          'get_shared_trip',
          params: <String, dynamic>{
            'p_token': share.url.substring(base.length),
          },
        );
        expect(rows as List<dynamic>, hasLength(1));
      },
    );

    test('the provider sees the funded job as money on its way', () async {
      final job = await provider.selectSingle(
        'jobs',
        'net_minor, actual_gateway_fee_minor',
        column: 'request_id',
        value: requestId,
      );
      final owed =
          (job!['net_minor'] as num).toInt() -
          ((job['actual_gateway_fee_minor'] as num?)?.toInt() ?? 0);
      final summary = await SupabaseWalletRepository(provider).getSummary();
      expect(summary.pending.minorUnits, owed);
      // Nothing recognised yet, so the feed has nothing posted to show.
      final feed = await SupabaseWalletRepository(provider).getTransactions();
      expect(feed.where((t) => t.amount.minorUnits > 0), isEmpty);
    });

    test(
      'provider travels, the pickup PIN starts the work, SOS is raised',
      () async {
        final jobs = SupabaseJobProgressRepository(provider);
        // The customer's screen follows without reloading: the project
        // publishes no table changes, so this is a broadcast on job:{id} or,
        // where Realtime is not running, the refresh timer.
        final followed = SupabaseRequestRepository(customer)
            .watchJob(requestId)
            .map((job) => job.status)
            .firstWhere((status) => status == JobStatus.enRoute)
            .timeout(const Duration(seconds: 30));
        await jobs.requestStatusChange(
          requestId,
          JobStatus.enRoute,
          idempotencyKey: newIdempotencyKey(),
        );
        expect(await followed, JobStatus.enRoute);

        // On the way, the position feeds the trip trail through the heartbeat
        // (ADR-0009). This stack runs without the Realtime service, so the
        // broadcast half fails and must not take the heartbeat with it.
        try {
          await SupabaseTrackingRepository(provider).publishProviderLocation(
            requestId,
            const LiveFix(
              point: GeoPoint(latitude: 6.5080, longitude: 3.3700),
              accuracyMetres: 9,
            ),
          );
        } on AppError {
          // The broadcast; the heartbeat has already run.
        }
        final trail = await provider.selectList(
          'location_samples',
          'request_id, is_mock',
          column: 'request_id',
          value: requestId,
        );
        expect(trail, hasLength(1));
        expect(trail.single['is_mock'], isFalse);
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
        // The provider reads it; the customer's own message then says Read.
        await SupabaseChatRepository(provider).markMessagesRead(requestId);
        final seen = await SupabaseChatRepository(customer)
            .watchMessages(requestId)
            .first;
        expect(seen.singleWhere((m) => m.id == chat.id).readAt, isNotNull);

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

    test('the provider home card counts the finished job', () async {
      final card = await SupabaseProviderRepository(provider).getHomeSummary();
      expect(card.completedToday, greaterThanOrEqualTo(1));
      expect(card.todayEarnings.minorUnits, greaterThan(0));
      expect(card.todayEarnings.currencyCode, 'NGN');
    });

    test('the provider keeps a week, a goal and sees their numbers', () async {
      final tools = SupabaseProviderToolsRepository(provider);
      final week = await tools.setAvailability(const <AvailabilitySlot>[
        AvailabilitySlot(dayOfWeek: 1, startMinutes: 540, endMinutes: 1020),
        AvailabilitySlot(dayOfWeek: 6, startMinutes: 600, endMinutes: 1440),
      ], idempotencyKey: newIdempotencyKey());
      expect(week, hasLength(2));
      expect(week.last.endMinutes, 1440);
      expect(await tools.getAvailability(), week);

      final goal = await tools.setEarningsGoal(
        const Money(10000000, 'NGN'),
        GoalPeriod.weekly,
        idempotencyKey: newIdempotencyKey(),
      );
      expect(goal.target, const Money(10000000, 'NGN'));
      // The confirmed job counts towards this week.
      expect(goal.progress.minorUnits, greaterThan(0));
      expect(goal.progress.currencyCode, 'NGN');

      final insights = await tools.getInsights();
      expect(insights.acceptanceRate, 1.0);
      expect(insights.periodDays, 30);

      // Demand: five open requests in one cell of a category this provider
      // serves. The heatmap shows the cell, never the pickups.
      final category = await service
          .from('service_categories')
          .select('id')
          .eq('key', 'errands_delivery')
          .single();
      await service.from('provider_services').upsert(<String, dynamic>{
        'provider_id': providerId,
        'category_id': category['id'],
      });
      await service.from('requests').insert(<Map<String, dynamic>>[
        for (var i = 0; i < 5; i++)
          <String, dynamic>{
            'customer_id': customerId,
            'country_code': 'NG',
            'category_id': category['id'],
            'description': 'E2E heatmap $i',
            'pickup_label': 'Lekki',
            'currency': 'NGN',
            'status': 'published',
            'pickup_point': 'SRID=4326;POINT(${3.4711 + i * 0.001} 6.4411)',
          },
      ]);
      final heatmap = await tools.getDemandHeatmap();
      final lekki = heatmap.where(
        (z) =>
            (z.center.latitude - 6.45).abs() < 1e-6 &&
            (z.center.longitude - 3.47).abs() < 1e-6,
      );
      expect(lekki, hasLength(1));
      expect(lekki.single.openRequests, greaterThanOrEqualTo(5));
      expect(lekki.single.intensity, inInclusiveRange(0.0, 1.0));
    });

    test(
      'a business registers, invites by phone, and dispatches to its worker',
      () async {
        Future<SupabaseGateway> signedIn(String email) async {
          final c = client(anonKey);
          addTearDown(c.dispose);
          await c.auth.signInWithPassword(email: email, password: password);
          return SupabaseGateway(c);
        }

        final digits = (run % 100000000).toString().padLeft(8, '0');
        final workerPhone = '+23481$digits';
        await createUser('e2e-owner-$run@suskii.test', provider: true);
        final workerId = await createUser(
          'e2e-worker-$run@suskii.test',
          provider: true,
          phone: workerPhone,
        );
        final owner = SupabaseOrganizationRepository(
          await signedIn('e2e-owner-$run@suskii.test'),
        );
        final worker = SupabaseOrganizationRepository(
          await signedIn('e2e-worker-$run@suskii.test'),
        );

        expect(await owner.getMyOrganization(), isNull);
        final org = await owner.registerOrganization(
          legalName: 'E2E Logistics $run',
          registrationNumber: 'RC$run',
          idempotencyKey: newIdempotencyKey(),
        );
        expect(org.name, 'E2E Logistics $run');
        expect(org.memberCount, 1);
        // One number, one business, however it is typed.
        await expectLater(
          worker.registerOrganization(
            legalName: 'Copycat',
            registrationNumber: 'rc $run',
            idempotencyKey: newIdempotencyKey(),
          ),
          throwsA(
            isA<AppError>().having(
              (e) => e.code,
              'code',
              'ERR_ORGANIZATION_ALREADY_REGISTERED',
            ),
          ),
        );

        final invited = await owner.inviteMember(
          phoneE164: workerPhone,
          role: BusinessRole.worker,
          idempotencyKey: newIdempotencyKey(),
        );
        // Not a member yet: the owner sees the number masked, not a name, and
        // an invitation id rather than the account's (Z.20).
        expect(invited.userId, isNot(workerId));
        expect(invited.displayName, isNot(contains(digits)));
        // A number with no account gets the same answer, in the same shape.
        final strangerDigits = ((run + 7) % 100000000).toString().padLeft(
          8,
          '0',
        );
        final stranger = await owner.inviteMember(
          phoneE164: '+23481$strangerDigits',
          role: BusinessRole.worker,
          idempotencyKey: newIdempotencyKey(),
        );
        expect(stranger.role, invited.role);
        expect(stranger.verificationStatus, invited.verificationStatus);
        expect(stranger.jobsCompleted, invited.jobsCompleted);
        expect(stranger.earningsToDate, invited.earningsToDate);
        expect(stranger.displayName, isNot(contains(strangerDigits)));
        await owner.removeMember(
          stranger.userId,
          idempotencyKey: newIdempotencyKey(),
        );
        expect(
          (await owner.getMembers()).map((m) => m.userId),
          isNot(contains(stranger.userId)),
        );

        final invitations = await worker.getMyInvitations();
        expect(invitations.single.organizationName, 'E2E Logistics $run');
        expect(invitations.single.role, BusinessRole.worker);
        final joined = await worker.acceptInvitation(
          org.id,
          idempotencyKey: newIdempotencyKey(),
        );
        expect(joined.id, org.id);
        expect(await worker.getMyInvitations(), isEmpty);
        final members = await owner.getMembers();
        expect(members, hasLength(2));
        expect(
          members.firstWhere((m) => m.userId == workerId).role,
          BusinessRole.worker,
        );

        final vehicle = await owner.upsertVehicle(
          Vehicle(
            id: 'new',
            organizationId: org.id,
            type: VehicleType.motorcycle,
            plate: 'LAG-$digits',
          ),
          idempotencyKey: newIdempotencyKey(),
        );
        expect(vehicle.type, VehicleType.motorcycle);
        expect(vehicle.plate, isNot(contains(digits)));
        final assigned = await owner.assignVehicle(
          vehicle.id,
          workerId,
          idempotencyKey: newIdempotencyKey(),
        );
        expect(assigned.assignedWorkerId, workerId);

        // A funded job the business won, handed to the worker.
        final categories = await SupabaseCatalogRepository(customer)
            .getCategories();
        final requests = SupabaseRequestRepository(customer);
        final draft = await requests.createRequest(
          CreateRequestInput(
            categoryId: categories.first.id,
            description: 'E2E: a job for the business',
            pickup: const PlaceRef(
              label: 'Ikeja',
              point: GeoPoint(latitude: 6.6018, longitude: 3.3515),
            ),
            preferredPrice: const Money(300000, 'NGN'),
          ),
          idempotencyKey: newIdempotencyKey(),
        );
        final published = await requests.publishRequest(
          draft.id,
          idempotencyKey: newIdempotencyKey(),
        );
        final ownerGateway = await signedIn('e2e-owner-$run@suskii.test');
        final offer = await SupabaseProviderRepository(ownerGateway)
            .submitOffer(
              requestId: published.id,
              amount: const Money(300000, 'NGN'),
              idempotencyKey: newIdempotencyKey(),
            );
        await SupabaseOfferRepository(customer)
            .acceptOffer(offer.id, idempotencyKey: newIdempotencyKey());
        // A promo the admin console created (four-eyes, applied by a second
        // super admin); here inserted directly, as that apply step does.
        final promoCode = 'E2E${run % 100000000}';
        await service.from('promo_codes').insert(<String, dynamic>{
          'code': promoCode,
          'country_code': 'NG',
          'currency': 'NGN',
          'discount_kind': 'percent',
          'discount_value': 1000,
          'max_discount_minor': 20000,
        });
        final payments = SupabasePaymentRepository(customer);
        await expectLater(
          payments.previewPromo(jobId: published.id, code: 'NOPE1234'),
          throwsA(
            isA<AppError>().having(
              (e) => e.code,
              'code',
              ErrorCodes.promoInvalid,
            ),
          ),
        );
        // 10% of 3,000.00 is 300.00, capped at 200.00; typed in lower case.
        final discount = await payments.previewPromo(
          jobId: published.id,
          code: promoCode.toLowerCase(),
        );
        expect(discount, const Money(20000, 'NGN'));
        final session = await payments.initializePayment(
          jobId: published.id,
          method: PaymentMethod.card,
          idempotencyKey: newIdempotencyKey(),
          promoCode: promoCode.toLowerCase(),
        );
        expect(session.payment.amount, const Money(280000, 'NGN'));
        final reference = 'e2e-org-$run';
        await service.rpc<dynamic>(
          'gateway_record_checkout',
          params: <String, dynamic>{
            'p_payment_id': session.payment.id,
            'p_gateway': 'flutterwave',
            'p_gateway_reference': reference,
            'p_checkout_url': 'https://checkout.example/$reference',
          },
        );
        await service.rpc<dynamic>(
          'gateway_confirm_payment',
          params: <String, dynamic>{
            'p_gateway': 'flutterwave',
            'p_gateway_reference': reference,
            'p_amount_minor': session.payment.amount.minorUnits,
            'p_fee_minor': 0,
          },
        );

        final assignable = await owner.getAssignableJobs();
        expect(assignable.map((j) => j.id), contains(published.id));
        final dispatched = await owner.assignJob(
          jobId: published.id,
          workerId: workerId,
          idempotencyKey: newIdempotencyKey(),
        );
        expect(dispatched.status, JobStatus.assigned);
        expect(
          (await owner.getAssignableJobs()).map((j) => j.id),
          isNot(contains(published.id)),
        );
      },
    );

    test('a dispute freezes the job', () async {
      final dispute = await SupabaseDisputeRepository(customer).openDispute(
        jobId: requestId,
        // The key the app's sheet sends; open_dispute only takes snake_case codes.
        reasonKey: 'disputeReasonNotDelivered',
        details: 'E2E dispute',
        idempotencyKey: newIdempotencyKey(),
      );
      expect(dispute.jobId, requestId);
      expect(dispute.reasonKey, 'disputeReasonNotDelivered');
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

    test('a trusted contact goes in as typed and comes back masked', () async {
      final settings = SupabaseSettingsRepository(customer);
      final contact = await settings.addTrustedContact(
        name: 'Mama',
        phoneE164: '+234 803 123 4567',
        idempotencyKey: newIdempotencyKey(),
      );
      expect(contact.phoneE164, '+234••••••4567');
      final list = await settings.getTrustedContacts();
      expect(list.map((c) => c.id), contains(contact.id));
      // What is stored is not the number.
      final raw = await service
          .from('trusted_contacts')
          .select('phone_ciphertext')
          .eq('id', contact.id)
          .single();
      expect(
        raw['phone_ciphertext'].toString(),
        isNot(contains('2348031234567')),
      );
    });

    test(
      'provider KYC: answers and numbers go in, review is not self-declared',
      () async {
        final kyc = SupabaseProviderKycRepository(provider);
        final afterAddress = await kyc.submitStep(
          KycStepKind.address,
          const AddressInput(
            line1: '12 Allen Avenue',
            city: 'Ikeja',
            state: 'Lagos',
            landmarkNote: 'Opposite the bank',
          ),
          idempotencyKey: newIdempotencyKey(),
        );
        final address = afterAddress.steps.firstWhere(
          (s) => s.kind == KycStepKind.address,
        );
        expect(address.status, KycStepStatus.inReview);
        expect(address.submittedAt, isNotNull);

        await kyc.submitStep(
          KycStepKind.governmentId,
          IdDocumentInput(idType: 'nin', idNumber: '9${run % 10000000000}'),
          idempotencyKey: newIdempotencyKey(),
        );
        await provider.rpc('record_consent', <String, Object?>{
          'p_idempotency_key': newIdempotencyKey(),
          'p_kind': 'criminal_record_check',
          'p_granted': true,
        });
        final afterPolice = await kyc.submitStep(
          KycStepKind.policeClearance,
          PoliceClearanceInput(
            certificateNumber: 'PC/2026/$run',
            issueDate: DateTime.now().subtract(const Duration(days: 30)),
            expiryDate: DateTime.now().add(const Duration(days: 150)),
            uploadRef: '$providerId/police.pdf',
          ),
          idempotencyKey: newIdempotencyKey(),
        );
        expect(
          afterPolice.steps
              .firstWhere((s) => s.kind == KycStepKind.policeClearance)
              .status,
          KycStepStatus.inReview,
        );
        // The liveness check waits on the identity vendor, so the profile is
        // incomplete and the server says so.
        await expectLater(
          kyc.submitForReview(idempotencyKey: newIdempotencyKey()),
          throwsA(
            isA<AppError>().having(
              (e) => e.code,
              'code',
              ErrorCodes.kycIncomplete,
            ),
          ),
        );
      },
    );

    test(
      'a customer ID lookup records the number and decides nothing',
      () async {
        final number = '8${run % 10000000000}';
        final session = await SupabaseVerificationRepository(customer)
            .submitIdLookup(
              'customer_facial',
              'nin',
              number,
              idempotencyKey: newIdempotencyKey(),
            );
        expect(session.kind, KycStepKind.customerFacial);
        expect(session.status, isNot(KycStepStatus.verified));
        // Recorded and indexed: the same number on a second account is refused,
        // matched without anybody reading it.
        await expectLater(
          SupabaseProviderKycRepository(provider).submitStep(
            KycStepKind.governmentId,
            IdDocumentInput(idType: 'nin', idNumber: number),
            idempotencyKey: newIdempotencyKey(),
          ),
          throwsA(
            isA<AppError>().having(
              (e) => e.code,
              'code',
              'ERR_IDENTITY_ALREADY_REGISTERED',
            ),
          ),
        );
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

    test('Suskii Meet: host, join, see who is going, cancel', () async {
      Future<SupabaseGateway> signedIn(String email) async {
        final c = client(anonKey);
        addTearDown(c.dispose);
        await c.auth.signInWithPassword(email: email, password: password);
        return SupabaseGateway(c);
      }

      await createUser('e2e-host-$run@suskii.test', provider: false);
      await createUser('e2e-guest-$run@suskii.test', provider: false);
      final host = SupabaseMeetupRepository(
        await signedIn('e2e-host-$run@suskii.test'),
      );
      final guest = SupabaseMeetupRepository(
        await signedIn('e2e-guest-$run@suskii.test'),
      );
      final start = DateTime.now().add(const Duration(days: 2));
      final id = await host.createMeetup(
        MeetupDraft(
          title: 'E2E picnic $run',
          description: 'Bring something to share.',
          topic: MeetupTopic.foodDrink,
          venueName: 'Muri Okunola Park',
          venue: const GeoPoint(latitude: 6.43, longitude: 3.42),
          startsAt: start,
          endsAt: start.add(const Duration(hours: 2)),
          capacity: 2,
        ),
        idempotencyKey: newIdempotencyKey(),
      );
      final near = await guest.listMeetups(
        near: const GeoPoint(latitude: 6.45, longitude: 3.40),
      );
      final found = near.singleWhere((Meetup m) => m.id == id);
      expect(found.isHost, isFalse);
      expect(found.distanceKm, isNotNull);
      await expectLater(
        guest.attendees(id),
        throwsA(
          isA<AppError>().having((e) => e.code, 'code', 'ERR_MEETUP_NOT_FOUND'),
        ),
      );
      expect(
        await guest.joinMeetup(id, idempotencyKey: newIdempotencyKey()),
        1,
      );
      expect(
        (await guest.attendees(id)).map((MeetupAttendee a) => a.isHost),
        <bool>[true, false],
      );
      expect((await guest.myMeetups()).any((Meetup m) => m.id == id), isTrue);
      await host.cancelMeetup(id, idempotencyKey: newIdempotencyKey());
      expect((await guest.getMeetup(id)).isCancelled, isTrue);
      expect(
        (await guest.listMeetups()).any((Meetup m) => m.id == id),
        isFalse,
      );
    });

    test('a sign-up without a country chooses it once; customers publish unverified', () async {
      final email = 'e2e-social-$run@suskii.test';
      await service.auth.admin.createUser(
        AdminUserAttributes(
          email: email,
          password: password,
          emailConfirm: true,
        ),
      );
      final c = client(anonKey);
      addTearDown(c.dispose);
      await c.auth.signInWithPassword(email: email, password: password);
      final gateway = SupabaseGateway(c);
      final users = SupabaseUserRepository(gateway);
      expect((await users.getProfile()).countryCode, isEmpty);
      await gateway.rpc('set_initial_country', <String, Object?>{
        'p_country_code': 'NG',
      });
      final profile = await users.getProfile();
      expect(profile.countryCode, 'NG');
      expect(profile.customerVerification, VerificationStatus.unverified);
      await expectLater(
        gateway.rpc('set_initial_country', <String, Object?>{
          'p_country_code': 'KE',
        }),
        throwsA(
          isA<AppError>().having(
            (e) => e.code,
            'code',
            'ERR_COUNTRY_ALREADY_SET',
          ),
        ),
      );

      final requests = SupabaseRequestRepository(gateway);
      final draft = await requests.createRequest(
        const CreateRequestInput(
          categoryId: 'mechanics',
          description: 'My car will not start; battery or starter.',
          pickup: PlaceRef(
            label: 'Allen Avenue, Ikeja',
            point: GeoPoint(latitude: 6.6018, longitude: 3.3515),
          ),
        ),
        idempotencyKey: newIdempotencyKey(),
      );
      final published = await requests.publishRequest(
        draft.id,
        idempotencyKey: newIdempotencyKey(),
      );
      expect(published.status, JobStatus.published);
    });

    test(
      'a provider picks a state; the customer sees who is near and how far',
      () async {
        Future<SupabaseGateway> signedIn(String email) async {
          final c = client(anonKey);
          addTearDown(c.dispose);
          await c.auth.signInWithPassword(email: email, password: password);
          return SupabaseGateway(c);
        }

        await createUser('e2e-near-p-$run@suskii.test', provider: true);
        await createUser('e2e-near-c-$run@suskii.test', provider: false);
        final p = await signedIn('e2e-near-p-$run@suskii.test');
        final c = await signedIn('e2e-near-c-$run@suskii.test');

        // The state goes over the wire by code: the name never matched before.
        final profile = await SupabaseProviderKycRepository(p).saveOnboarding(
          const ProviderOnboardingInput(
            kind: ProviderKind.individual,
            serviceCategoryIds: <String>['plumbing'],
            serviceAreaIds: <String>['kano'],
          ),
          idempotencyKey: newIdempotencyKey(),
        );
        expect(profile.serviceAreaIds, <String>['kano']);
        await SupabaseProviderRepository(p)
            .setOnline(true, idempotencyKey: newIdempotencyKey());
        // What both apps now do every 45 s while online: without it the
        // provider has no fresh position and matching never considers them.
        await SupabaseTrackingRepository(p).reportPosition(
          const LiveFix(point: GeoPoint(latitude: 12.0030, longitude: 8.5925)),
        );

        const pickup = GeoPoint(latitude: 12.0022, longitude: 8.5920);
        final nearby = await SupabaseCatalogRepository(c)
            .getNearbyProviders(at: pickup, categoryId: 'plumbing');
        expect(nearby.total, 1);
        // One provider is below the floor of three: counted, never placed.
        expect(nearby.areas, isEmpty);

        final requests = SupabaseRequestRepository(c);
        final draft = await requests.createRequest(
          const CreateRequestInput(
            categoryId: 'plumbing',
            description: 'A leaking kitchen tap.',
            pickup: PlaceRef(label: 'Zoo Road, Kano', point: pickup),
          ),
          idempotencyKey: newIdempotencyKey(),
        );
        await requests.publishRequest(
          draft.id,
          idempotencyKey: newIdempotencyKey(),
        );
        await SupabaseProviderRepository(p).submitOffer(
          requestId: draft.id,
          amount: const Money(800000, 'NGN'),
          idempotencyKey: newIdempotencyKey(),
        );
        final ranked = await SupabaseOfferRepository(c)
            .getRankedOffers(draft.id);
        expect(ranked.single.distanceKm, 0.5);
      },
    );
  });
}

/// The smallest valid JPEG: enough for Storage's content-type check.
final List<int> _jpeg = <int>[
  0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, //
  0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0xFF, 0xD9,
];
