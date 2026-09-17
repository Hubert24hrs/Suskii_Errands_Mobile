import 'dart:async';

import 'package:suskii_domain/suskii_domain.dart';

import 'server_sim.dart';

/// Per-language voice-concierge availability for the mock backend, mirroring
/// `remote_config.voice_languages` (OD-17: Pidgin ships text-only until the
/// voice gate passes). Served on `AppBootstrap.voiceLanguages` and injected
/// into `MockVoiceConciergeAdapter` so both read the same source.
const Map<String, bool> kMockVoiceLanguages = <String, bool>{
  'en': true,
  'pcm': false,
};

/// In-memory mock "database". Mutable, seeded with realistic fixtures covering
/// the spec's required edge cases: expired offers, failed payment, disputed
/// job, suspended provider, expired police clearance, unverified user, empty
/// lists, and NGN/KES/GHS/ZAR/USD currencies.
class MockDatabase {
  MockDatabase() {
    _seed();
  }

  /// When true, setOnline(true) throws ERR_PROVIDER_BUSY_AS_CUSTOMER if the
  /// current user has a customer job stuck in a state that needs attention.
  bool providerBusyRuleEnabled = false;

  late final Map<String, AppUser> users;
  late final Map<String, ProviderProfile> providers;
  late final List<ServiceCategory> categories;
  late final Map<String, CountryPack> countryPacks;
  late final Map<String, JobRequest> requests;
  late final Map<String, List<Offer>> offers;
  late final Map<String, List<ChatMessage>> chats;
  late final Map<String, WalletSummary> wallets;
  late final Map<String, List<WalletTransaction>> walletTransactions;
  late final Map<String, ReferralSummary> referrals;
  late final List<AppNotification> notifications;

  /// Customer facial-verification sessions, keyed by user id.
  late final Map<String, VerificationSession> verificationSessions;

  /// Provider KYC profiles, keyed by user id. Personas: `user-chidi` is the
  /// unverified user (no profile yet), `user-emeka` has a rejected police
  /// clearance, `user-ada` is fully verified.
  late final Map<String, ProviderKycProfile> kycProfiles;

  final StreamController<AppNotification> notificationEvents =
      StreamController<AppNotification>.broadcast();
  final StreamController<JobRequest> jobEvents =
      StreamController<JobRequest>.broadcast();
  final StreamController<Offer> offerEvents =
      StreamController<Offer>.broadcast();
  final StreamController<ProviderKycProfile> kycEvents =
      StreamController<ProviderKycProfile>.broadcast();

  void _seed() {
    final now = DateTime.now();

    users = <String, AppUser>{
      'user-ada': AppUser(
        id: 'user-ada',
        displayName: 'Adaeze Obi',
        phoneE164: '+2348012345678',
        email: 'ada@example.com',
        countryCode: 'NG',
        preferredLanguage: 'en',
        activeMode: UserMode.customer,
        customerVerification: VerificationStatus.verified,
        providerVerification: VerificationStatus.verified,
        trustLevel: TrustLevel.trusted,
        referralCode: 'ADA-7K2',
        createdAt: now.subtract(const Duration(days: 120)),
      ),
      'user-chidi': AppUser(
        id: 'user-chidi',
        displayName: 'Chidi Eze',
        phoneE164: '+2348098765432',
        countryCode: 'NG',
        preferredLanguage: 'pcm',
        activeMode: UserMode.customer,
        customerVerification: VerificationStatus.unverified,
        providerVerification: VerificationStatus.unverified,
        trustLevel: TrustLevel.new_,
        createdAt: now.subtract(const Duration(days: 2)),
      ),
      'user-kofi': AppUser(
        id: 'user-kofi',
        displayName: 'Kofi Mensah',
        phoneE164: '+233201112233',
        countryCode: 'GH',
        preferredLanguage: 'en',
        activeMode: UserMode.customer,
        customerVerification: VerificationStatus.verified,
        providerVerification: VerificationStatus.pending,
        trustLevel: TrustLevel.verified,
        createdAt: now.subtract(const Duration(days: 30)),
      ),
      // Rejected-police-clearance persona for the provider KYC demo.
      'user-emeka': AppUser(
        id: 'user-emeka',
        displayName: 'Emeka Nwosu',
        phoneE164: '+2348055500112',
        email: 'emeka@example.com',
        countryCode: 'NG',
        preferredLanguage: 'en',
        activeMode: UserMode.customer,
        customerVerification: VerificationStatus.verified,
        providerVerification: VerificationStatus.rejected,
        trustLevel: TrustLevel.new_,
        createdAt: now.subtract(const Duration(days: 15)),
      ),
    };

    providers = <String, ProviderProfile>{
      'provider-musa': const ProviderProfile(
        userId: 'provider-musa',
        displayName: 'Musa Bello',
        kind: ProviderKind.individual,
        serviceCategoryIds: <String>['errands_delivery', 'food_pickup'],
        serviceAreaIds: <String>['lagos-lekki', 'lagos-vi'],
        rating: 4.7,
        completedJobs: 312,
        cancellationRate: 0.02,
        avgResponseTimeSeconds: 95,
        online: true,
        verificationStatus: VerificationStatus.verified,
        vehicleType: VehicleType.motorcycle,
      ),
      'provider-ngozi': const ProviderProfile(
        userId: 'provider-ngozi',
        displayName: 'Ngozi Adeyemi',
        kind: ProviderKind.individual,
        serviceCategoryIds: <String>['moving', 'shopping'],
        serviceAreaIds: <String>['lagos-lekki'],
        rating: 4.9,
        completedJobs: 540,
        cancellationRate: 0.01,
        avgResponseTimeSeconds: 60,
        online: true,
        verificationStatus: VerificationStatus.verified,
        vehicleType: VehicleType.van,
      ),
      'provider-tunde': const ProviderProfile(
        userId: 'provider-tunde',
        displayName: 'Tunde Bakare',
        kind: ProviderKind.individual,
        serviceCategoryIds: <String>['errands_delivery'],
        serviceAreaIds: <String>['lagos-ikeja'],
        rating: 3.8,
        completedJobs: 44,
        cancellationRate: 0.18,
        avgResponseTimeSeconds: 420,
        online: false,
        verificationStatus: VerificationStatus.suspended,
        vehicleType: VehicleType.bicycle,
      ),
      'provider-swift': const ProviderProfile(
        userId: 'provider-swift',
        displayName: 'SwiftErrands Ltd',
        businessName: 'SwiftErrands Ltd',
        kind: ProviderKind.business,
        serviceCategoryIds: <String>['errands_delivery', 'document_delivery'],
        serviceAreaIds: <String>['lagos-lekki', 'lagos-vi', 'lagos-ikoyi'],
        rating: 4.5,
        completedJobs: 1820,
        cancellationRate: 0.03,
        avgResponseTimeSeconds: 130,
        online: true,
        verificationStatus: VerificationStatus.verified,
        vehicleType: VehicleType.car,
      ),
      'provider-kwame': const ProviderProfile(
        userId: 'provider-kwame',
        displayName: 'Kwame Asante',
        kind: ProviderKind.individual,
        serviceCategoryIds: <String>['errands_delivery'],
        serviceAreaIds: <String>['accra-osu'],
        rating: 4.6,
        completedJobs: 210,
        cancellationRate: 0.04,
        avgResponseTimeSeconds: 110,
        online: true,
        verificationStatus: VerificationStatus.expired,
        vehicleType: VehicleType.motorcycle,
      ),
    };

    // Growable (not const) so tests/demo can override per-category
    // negotiation config (offerTtlSeconds, maxCounterRounds).
    categories = <ServiceCategory>[
      const ServiceCategory(
        id: 'errands_delivery',
        labelKey: 'catErrandsDelivery',
        iconKey: 'package',
        allowsCustom: false,
      ),
      const ServiceCategory(
        id: 'shopping',
        labelKey: 'catShopping',
        iconKey: 'cart',
        allowsCustom: false,
      ),
      const ServiceCategory(
        id: 'cleaning_laundry',
        labelKey: 'catCleaningLaundry',
        iconKey: 'sparkles',
        allowsCustom: false,
      ),
      const ServiceCategory(
        id: 'moving',
        labelKey: 'catMoving',
        iconKey: 'truck',
        allowsCustom: false,
      ),
      const ServiceCategory(
        id: 'repairs',
        labelKey: 'catRepairs',
        iconKey: 'wrench',
        allowsCustom: false,
      ),
      const ServiceCategory(
        id: 'personal_assistance',
        labelKey: 'catPersonalAssistance',
        iconKey: 'person',
        allowsCustom: false,
      ),
      const ServiceCategory(
        id: 'document_delivery',
        labelKey: 'catDocumentDelivery',
        iconKey: 'document',
        allowsCustom: false,
      ),
      const ServiceCategory(
        id: 'food_pickup',
        labelKey: 'catFoodPickup',
        iconKey: 'food',
        allowsCustom: false,
      ),
      const ServiceCategory(
        id: 'transportation',
        labelKey: 'catTransportation',
        iconKey: 'car',
        allowsCustom: false,
      ),
      const ServiceCategory(
        id: 'tech_business',
        labelKey: 'catTechBusiness',
        iconKey: 'laptop',
        allowsCustom: false,
      ),
      const ServiceCategory(
        id: 'event_assistance',
        labelKey: 'catEventAssistance',
        iconKey: 'calendar',
        allowsCustom: false,
      ),
      const ServiceCategory(
        id: 'custom',
        labelKey: 'catCustom',
        iconKey: 'magic',
        allowsCustom: true,
      ),
    ];

    countryPacks = <String, CountryPack>{
      'NG': const CountryPack(
        countryCode: 'NG',
        status: CountryStatus.live,
        currencyCode: 'NGN',
        supportedLanguages: <String>['en', 'pcm'],
        defaultLanguage: 'en',
        launchCities: <String>['Lagos', 'Abuja', 'Port Harcourt'],
        emergencyNumbers: <EmergencyNumber>[
          EmergencyNumber(labelKey: 'emergencyPolice', number: '112'),
          EmergencyNumber(labelKey: 'emergencyAmbulance', number: '112'),
        ],
        offerTtlSeconds: 600,
        maxNegotiationRounds: 5,
        minWithdrawal: Money(100000, 'NGN'),
      ),
      'KE': const CountryPack(
        countryCode: 'KE',
        status: CountryStatus.beta,
        currencyCode: 'KES',
        supportedLanguages: <String>['en'],
        defaultLanguage: 'en',
        launchCities: <String>['Nairobi'],
        emergencyNumbers: <EmergencyNumber>[
          EmergencyNumber(labelKey: 'emergencyPolice', number: '999'),
        ],
        offerTtlSeconds: 600,
        maxNegotiationRounds: 5,
        minWithdrawal: Money(20000, 'KES'),
      ),
      'GH': const CountryPack(
        countryCode: 'GH',
        status: CountryStatus.beta,
        currencyCode: 'GHS',
        supportedLanguages: <String>['en'],
        defaultLanguage: 'en',
        launchCities: <String>['Accra'],
        emergencyNumbers: <EmergencyNumber>[
          EmergencyNumber(labelKey: 'emergencyPolice', number: '191'),
        ],
        offerTtlSeconds: 600,
        maxNegotiationRounds: 5,
        minWithdrawal: Money(5000, 'GHS'),
      ),
      'ZA': const CountryPack(
        countryCode: 'ZA',
        status: CountryStatus.disabled,
        currencyCode: 'ZAR',
        supportedLanguages: <String>['en'],
        defaultLanguage: 'en',
        launchCities: <String>[],
        emergencyNumbers: <EmergencyNumber>[
          EmergencyNumber(labelKey: 'emergencyPolice', number: '10111'),
        ],
        offerTtlSeconds: 600,
        maxNegotiationRounds: 5,
      ),
      'US': const CountryPack(
        countryCode: 'US',
        status: CountryStatus.disabled,
        currencyCode: 'USD',
        supportedLanguages: <String>['en'],
        defaultLanguage: 'en',
        launchCities: <String>[],
        emergencyNumbers: <EmergencyNumber>[
          EmergencyNumber(labelKey: 'emergencyGeneral', number: '911'),
        ],
        offerTtlSeconds: 600,
        maxNegotiationRounds: 5,
        minWithdrawal: Money(1000, 'USD'),
      ),
    };

    requests = <String, JobRequest>{
      'req-1': JobRequest(
        id: 'req-1',
        customerId: 'user-ada',
        categoryId: 'shopping',
        isCustomCategory: false,
        description: 'Buy groceries from Spar Lekki — list attached as photo.',
        mediaPaths: const <String>['mock://media/list1.jpg'],
        pickup: const PlaceRef(
          label: 'Spar, Lekki Phase 1',
          point: GeoPoint(latitude: 6.4474, longitude: 3.4723),
          landmarkNote: 'Opposite the roundabout, blue gate',
        ),
        destination: const PlaceRef(
          label: 'Home — Admiralty Way',
          point: GeoPoint(latitude: 6.4311, longitude: 3.4359),
        ),
        urgency: Urgency.standard,
        status: JobStatus.negotiating,
        createdAt: now.subtract(const Duration(minutes: 12)),
        preferredPrice: const Money(500000, 'NGN'),
        itemFloat: const Money(1500000, 'NGN'),
        expiresAt: now.add(const Duration(hours: 4)),
      ),
      'req-2': JobRequest(
        id: 'req-2',
        customerId: 'user-ada',
        categoryId: 'food_pickup',
        isCustomCategory: false,
        description: 'Pick up my order from Chicken Republic, Admiralty.',
        mediaPaths: const <String>[],
        pickup: const PlaceRef(
          label: 'Chicken Republic, Admiralty Way',
          point: GeoPoint(latitude: 6.4281, longitude: 3.4219),
        ),
        destination: const PlaceRef(
          label: 'Home — Admiralty Way',
          point: GeoPoint(latitude: 6.4311, longitude: 3.4359),
        ),
        urgency: Urgency.urgent,
        status: JobStatus.enRoute,
        createdAt: now.subtract(const Duration(minutes: 40)),
        agreedPrice: const Money(320000, 'NGN'),
        agreedBreakdown: simulateQuote(
          const Money(320000, 'NGN'),
          estimatedGatewayFee: const Money(4800, 'NGN'),
        ),
        providerId: 'provider-musa',
      ),
      'req-3': JobRequest(
        id: 'req-3',
        customerId: 'user-ada',
        categoryId: 'document_delivery',
        isCustomCategory: false,
        description: 'Deliver signed documents to a law office on Ikoyi.',
        mediaPaths: const <String>[],
        pickup: const PlaceRef(
          label: 'Home — Admiralty Way',
          point: GeoPoint(latitude: 6.4311, longitude: 3.4359),
        ),
        destination: const PlaceRef(
          label: 'Law office, Bourdillon Rd, Ikoyi',
          point: GeoPoint(latitude: 6.4527, longitude: 3.4320),
        ),
        urgency: Urgency.standard,
        status: JobStatus.disputed,
        createdAt: now.subtract(const Duration(days: 1, hours: 3)),
        agreedPrice: const Money(450000, 'NGN'),
        agreedBreakdown: simulateQuote(
          const Money(450000, 'NGN'),
          estimatedGatewayFee: const Money(6750, 'NGN'),
        ),
        providerId: 'provider-swift',
        declaredValue: const Money(5000000, 'NGN'),
      ),
      'req-4': JobRequest(
        id: 'req-4',
        customerId: 'user-ada',
        categoryId: 'cleaning_laundry',
        isCustomCategory: false,
        description: 'Deep clean a 2-bedroom apartment.',
        mediaPaths: const <String>[],
        pickup: const PlaceRef(
          label: 'Home — Admiralty Way',
          point: GeoPoint(latitude: 6.4311, longitude: 3.4359),
        ),
        urgency: Urgency.flexible,
        status: JobStatus.closed,
        createdAt: now.subtract(const Duration(days: 6)),
        agreedPrice: const Money(2500000, 'NGN'),
        agreedBreakdown: simulateQuote(
          const Money(2500000, 'NGN'),
          estimatedGatewayFee: const Money(37500, 'NGN'),
          tip: const Money(200000, 'NGN'),
        ),
        providerId: 'provider-ngozi',
      ),
      'req-5': JobRequest(
        id: 'req-5',
        customerId: 'user-ada',
        categoryId: 'custom',
        isCustomCategory: true,
        description: 'Help me queue for passport photos and print forms.',
        mediaPaths: const <String>[],
        pickup: const PlaceRef(label: 'Ikoyi Passport Office'),
        urgency: Urgency.standard,
        status: JobStatus.draft,
        createdAt: now.subtract(const Duration(minutes: 55)),
        preferredPrice: const Money(700000, 'NGN'),
        scheduledAt: now.add(const Duration(days: 1, hours: 2)),
      ),
      'req-6': JobRequest(
        id: 'req-6',
        customerId: 'user-ada',
        categoryId: 'errands_delivery',
        isCustomCategory: false,
        description: 'Collect a parcel from a vendor in Yaba.',
        mediaPaths: const <String>[],
        pickup: const PlaceRef(
          label: 'Yaba market stall 14',
          point: GeoPoint(latitude: 6.5095, longitude: 3.3711),
        ),
        destination: const PlaceRef(label: 'Home — Admiralty Way'),
        urgency: Urgency.standard,
        status: JobStatus.paymentPending,
        createdAt: now.subtract(const Duration(minutes: 25)),
        agreedPrice: const Money(400000, 'NGN'),
        agreedBreakdown: simulateQuote(
          const Money(400000, 'NGN'),
          estimatedGatewayFee: const Money(6000, 'NGN'),
        ),
        providerId: 'provider-swift',
        expiresAt: now.add(const Duration(minutes: 9)),
      ),
      // Nearby open requests for the provider feed (multi-currency coverage).
      'req-feed-1': JobRequest(
        id: 'req-feed-1',
        customerId: 'user-chidi',
        categoryId: 'errands_delivery',
        isCustomCategory: false,
        description: 'Deliver a small package from VI to Lekki.',
        mediaPaths: const <String>[],
        pickup: const PlaceRef(
          label: 'Adeola Odeku St, VI',
          point: GeoPoint(latitude: 6.4281, longitude: 3.4219),
        ),
        destination: const PlaceRef(label: 'Lekki Phase 1'),
        urgency: Urgency.urgent,
        status: JobStatus.published,
        createdAt: now.subtract(const Duration(minutes: 4)),
        preferredPrice: const Money(350000, 'NGN'),
      ),
      'req-feed-2': JobRequest(
        id: 'req-feed-2',
        customerId: 'user-kofi',
        categoryId: 'shopping',
        isCustomCategory: false,
        description: 'Buy phone accessories at Accra Mall.',
        mediaPaths: const <String>[],
        pickup: const PlaceRef(
          label: 'Accra Mall',
          point: GeoPoint(latitude: 5.6365, longitude: -0.1607),
        ),
        urgency: Urgency.standard,
        status: JobStatus.published,
        createdAt: now.subtract(const Duration(minutes: 20)),
        preferredPrice: const Money(8500, 'GHS'),
      ),
      'req-feed-3': JobRequest(
        id: 'req-feed-3',
        customerId: 'user-ke-1',
        categoryId: 'document_delivery',
        isCustomCategory: false,
        description: 'Take contracts from Westlands to CBD Nairobi.',
        mediaPaths: const <String>[],
        pickup: const PlaceRef(
          label: 'Westlands, Nairobi',
          point: GeoPoint(latitude: -1.2635, longitude: 36.8078),
        ),
        urgency: Urgency.standard,
        status: JobStatus.published,
        createdAt: now.subtract(const Duration(minutes: 33)),
        preferredPrice: const Money(45000, 'KES'),
      ),
      'req-feed-4': JobRequest(
        id: 'req-feed-4',
        customerId: 'user-za-1',
        categoryId: 'errands_delivery',
        isCustomCategory: false,
        description: 'Collect keys from an office in Sandton.',
        mediaPaths: const <String>[],
        pickup: const PlaceRef(
          label: 'Sandton City',
          point: GeoPoint(latitude: -26.1076, longitude: 28.0567),
        ),
        urgency: Urgency.flexible,
        status: JobStatus.published,
        createdAt: now.subtract(const Duration(hours: 1)),
        preferredPrice: const Money(12000, 'ZAR'),
      ),
      'req-feed-5': JobRequest(
        id: 'req-feed-5',
        customerId: 'user-us-1',
        categoryId: 'personal_assistance',
        isCustomCategory: false,
        description: 'Wait for a furniture delivery and sign for it.',
        mediaPaths: const <String>[],
        pickup: const PlaceRef(label: 'Austin, TX'),
        urgency: Urgency.standard,
        status: JobStatus.published,
        createdAt: now.subtract(const Duration(hours: 2)),
        preferredPrice: const Money(4500, 'USD'),
      ),
    };

    offers = <String, List<Offer>>{
      'req-1': <Offer>[
        Offer(
          id: 'offer-1a',
          requestId: 'req-1',
          providerId: 'provider-musa',
          providerName: 'Musa Bello',
          providerRating: 4.7,
          providerTrustLevel: TrustLevel.verified,
          amount: const Money(650000, 'NGN'),
          status: OfferStatus.pending,
          round: 1,
          createdAt: now.subtract(const Duration(minutes: 8)),
          message: 'I dey near Spar now, I fit do am quick.',
          distanceMeters: 900,
          payoutEstimate: simulateQuote(
            const Money(650000, 'NGN'),
            estimatedGatewayFee: const Money(9750, 'NGN'),
          ),
          expiresAt: now.add(const Duration(minutes: 9)),
        ),
        Offer(
          id: 'offer-1b',
          requestId: 'req-1',
          providerId: 'provider-swift',
          providerName: 'SwiftErrands Ltd',
          providerRating: 4.5,
          providerTrustLevel: TrustLevel.elite,
          amount: const Money(580000, 'NGN'),
          status: OfferStatus.countered,
          round: 2,
          createdAt: now.subtract(const Duration(minutes: 5)),
          distanceMeters: 2400,
          payoutEstimate: simulateQuote(
            const Money(580000, 'NGN'),
            estimatedGatewayFee: const Money(8700, 'NGN'),
          ),
          expiresAt: now.add(const Duration(minutes: 6)),
        ),
        Offer(
          id: 'offer-1c',
          requestId: 'req-1',
          providerId: 'provider-tunde',
          providerName: 'Tunde Bakare',
          providerRating: 3.8,
          providerTrustLevel: TrustLevel.new_,
          amount: const Money(500000, 'NGN'),
          status: OfferStatus.expired,
          round: 1,
          createdAt: now.subtract(const Duration(minutes: 11)),
          distanceMeters: 5100,
          expiresAt: now.subtract(const Duration(minutes: 1)),
        ),
      ],
    };

    chats = <String, List<ChatMessage>>{
      'req-2': <ChatMessage>[
        ChatMessage(
          id: 'msg-1',
          jobId: 'req-2',
          senderId: 'user-ada',
          type: ChatMessageType.text,
          text: 'Please ask them to add extra pepper sauce.',
          createdAt: now.subtract(const Duration(minutes: 30)),
          readAt: now.subtract(const Duration(minutes: 29)),
        ),
        ChatMessage(
          id: 'msg-2',
          jobId: 'req-2',
          senderId: 'provider-musa',
          type: ChatMessageType.text,
          text: 'Done. I don pick the order, I dey come now.',
          createdAt: now.subtract(const Duration(minutes: 12)),
        ),
        ChatMessage(
          id: 'msg-3',
          jobId: 'req-2',
          senderId: 'system',
          type: ChatMessageType.system,
          text: 'Provider is on the way',
          createdAt: now.subtract(const Duration(minutes: 12)),
        ),
      ],
    };

    wallets = <String, WalletSummary>{
      'user-ada': const WalletSummary(
        available: Money(1845000, 'NGN'),
        pending: Money(320000, 'NGN'),
        lifetimeEarned: Money(8420000, 'NGN'),
      ),
    };

    walletTransactions = <String, List<WalletTransaction>>{
      'user-ada': <WalletTransaction>[
        WalletTransaction(
          id: 'txn-1',
          kind: WalletTransactionKind.payout,
          status: WalletTransactionStatus.completed,
          amount: const Money(2175000, 'NGN'),
          referenceId: 'req-4',
          descriptionKey: 'txnPayoutCleaning',
          createdAt: now.subtract(const Duration(days: 5)),
        ),
        WalletTransaction(
          id: 'txn-2',
          kind: WalletTransactionKind.tip,
          status: WalletTransactionStatus.completed,
          amount: const Money(200000, 'NGN'),
          referenceId: 'req-4',
          descriptionKey: 'txnTip',
          createdAt: now.subtract(const Duration(days: 5)),
        ),
        WalletTransaction(
          id: 'txn-3',
          kind: WalletTransactionKind.referral,
          status: WalletTransactionStatus.completed,
          amount: const Money(54300, 'NGN'),
          descriptionKey: 'txnReferral',
          createdAt: now.subtract(const Duration(days: 3)),
        ),
        WalletTransaction(
          id: 'txn-4',
          kind: WalletTransactionKind.refund,
          status: WalletTransactionStatus.completed,
          amount: const Money(150000, 'NGN'),
          descriptionKey: 'txnRefundItemFloat',
          createdAt: now.subtract(const Duration(days: 2)),
        ),
      ],
    };

    referrals = <String, ReferralSummary>{
      'user-ada': const ReferralSummary(
        code: 'ADA-7K2',
        shareLink: 'https://suskii.app/r/ADA-7K2',
        invitedCount: 14,
        activeReferrals: 5,
        earnedTotal: Money(1245000, 'NGN'),
        holding: Money(105000, 'NGN'),
        available: Money(1140000, 'NGN'),
      ),
    };

    notifications = <AppNotification>[
      AppNotification(
        id: 'ntf-1',
        kind: 'offer',
        title: 'New offer from Musa Bello',
        body: '₦6,500.00 for your shopping request',
        read: false,
        createdAt: now.subtract(const Duration(minutes: 8)),
        deeplink: '/customer/requests/req-1/offers',
      ),
      AppNotification(
        id: 'ntf-2',
        kind: 'job',
        title: 'Provider on the way',
        body: 'Your food pickup is en route',
        read: true,
        createdAt: now.subtract(const Duration(minutes: 12)),
        deeplink: '/customer/requests/req-2/track',
      ),
    ];

    verificationSessions = <String, VerificationSession>{
      'user-ada': VerificationSession(
        id: 'vs-user-ada',
        kind: KycStepKind.customerFacial,
        status: KycStepStatus.verified,
        updatedAt: now.subtract(const Duration(days: 100)),
      ),
    };

    KycStep step(
      KycStepKind kind,
      KycStepStatus status, {
      int attemptCount = 0,
      String? rejectionReasonKey,
    }) => KycStep(
      kind: kind,
      status: status,
      attemptCount: attemptCount,
      submittedAt: status == KycStepStatus.notStarted
          ? null
          : now.subtract(const Duration(days: 10)),
      reviewedAt:
          status == KycStepStatus.verified || status == KycStepStatus.rejected
          ? now.subtract(const Duration(days: 9))
          : null,
      rejectionReasonKey: rejectionReasonKey,
    );

    KycStep verified(KycStepKind kind) =>
        step(kind, KycStepStatus.verified, attemptCount: 1);

    kycProfiles = <String, ProviderKycProfile>{
      'user-ada': ProviderKycProfile(
        userId: 'user-ada',
        kind: ProviderKind.individual,
        serviceCategoryIds: const <String>['errands_delivery', 'food_pickup'],
        serviceAreaIds: const <String>['lagos-lekki', 'lagos-vi'],
        vehicleType: VehicleType.motorcycle,
        steps: <KycStep>[
          verified(KycStepKind.governmentId),
          verified(KycStepKind.providerFacial),
          verified(KycStepKind.idDocumentCapture),
          verified(KycStepKind.policeClearance),
          verified(KycStepKind.address),
          verified(KycStepKind.guarantor),
          verified(KycStepKind.payoutAccount),
          verified(KycStepKind.vehicleDocuments),
          step(KycStepKind.credentials, KycStepStatus.notStarted),
        ],
        overallStatus: KycStepStatus.verified,
        submittedForReviewAt: now.subtract(const Duration(days: 9)),
      ),
      'user-emeka': ProviderKycProfile(
        userId: 'user-emeka',
        kind: ProviderKind.individual,
        serviceCategoryIds: const <String>['errands_delivery'],
        serviceAreaIds: const <String>['lagos-ikeja'],
        vehicleType: VehicleType.bicycle,
        steps: <KycStep>[
          verified(KycStepKind.governmentId),
          verified(KycStepKind.providerFacial),
          verified(KycStepKind.idDocumentCapture),
          step(
            KycStepKind.policeClearance,
            KycStepStatus.rejected,
            attemptCount: 1,
            rejectionReasonKey: 'kycRejectPoliceClearanceExpired',
          ),
          step(KycStepKind.address, KycStepStatus.notStarted),
          step(KycStepKind.guarantor, KycStepStatus.inReview, attemptCount: 1),
          step(KycStepKind.payoutAccount, KycStepStatus.notStarted),
          step(KycStepKind.vehicleDocuments, KycStepStatus.notStarted),
          step(KycStepKind.credentials, KycStepStatus.notStarted),
        ],
        overallStatus: KycStepStatus.rejected,
        submittedForReviewAt: now.subtract(const Duration(days: 9)),
      ),
    };
  }
}
