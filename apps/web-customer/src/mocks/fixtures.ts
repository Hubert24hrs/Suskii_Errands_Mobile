// In-memory mock "database", seeded with realistic fixtures mirroring
// packages/suskii_data/lib/src/mock/fixtures.dart (customer scope). Covers
// the spec's required edge cases: expired offer, disputed job, draft,
// payment-pending TTL, unverified persona, empty lists.

import { Emitter, simulateQuote } from './behavior';
import type {
  AppNotification,
  AppUser,
  ChatMessage,
  CountryPack,
  Dispute,
  JobRequest,
  NotificationPreferences,
  Offer,
  Payment,
  Promo,
  ProviderProfile,
  Rating,
  ReferralSummary,
  ServiceCategory,
  SosAlert,
  SupportTicket,
  TrustedContact,
  VerificationSession,
  WalletSummary,
  WalletTransaction,
} from './types';

/**
 * Per-language voice-concierge availability for the mock backend (OD-17:
 * Pidgin ships text-only until the voice gate passes).
 */
export const kMockVoiceLanguages: Record<string, boolean> = {
  en: true,
  pcm: false,
};

function minutesFrom(base: number, minutes: number): Date {
  return new Date(base + minutes * 60_000);
}
function hoursFrom(base: number, hours: number): Date {
  return new Date(base + hours * 3_600_000);
}
function daysFrom(base: number, days: number): Date {
  return new Date(base + days * 86_400_000);
}

export class MockDatabase {
  users: Record<string, AppUser> = {};
  providers: Record<string, ProviderProfile> = {};
  categories: ServiceCategory[] = [];
  countryPacks: Record<string, CountryPack> = {};
  requests: Record<string, JobRequest> = {};
  offers: Record<string, Offer[]> = {};
  chats: Record<string, ChatMessage[]> = {};
  wallets: Record<string, WalletSummary> = {};
  walletTransactions: Record<string, WalletTransaction[]> = {};
  referrals: Record<string, ReferralSummary> = {};
  notifications: AppNotification[] = [];

  /** Payments by id, plus the jobId → paymentId index (one payment per job). */
  payments: Record<string, Payment> = {};
  paymentByJob: Record<string, string> = {};

  /** Ratings per job (both directions live in one list). */
  ratings: Record<string, Rating[]> = {};

  /** Latest SOS alert per job. */
  sosAlerts: Record<string, SosAlert> = {};

  /** Disputes by job id (at most one per job). */
  disputes: Record<string, Dispute> = {};

  /** Support tickets by id. */
  tickets: Record<string, SupportTicket> = {};

  /** Promo campaigns by code. */
  promos: Record<string, Promo> = {};

  /** Notification preferences by user id. */
  notificationPrefs: Record<string, NotificationPreferences> = {};

  /** Trusted contacts by user id (max 5 per user). */
  trustedContacts: Record<string, TrustedContact[]> = {};

  /** Customer facial-verification sessions, keyed by user id. */
  verificationSessions: Record<string, VerificationSession> = {};

  /**
   * When each job reached `confirmed` — drives the chat window (open for
   * 24h after confirmation unless a dispute is open).
   */
  jobConfirmedAt: Record<string, Date> = {};

  // Event channels (stand-ins for the Dart broadcast StreamControllers).
  readonly notificationEvents = new Emitter<AppNotification>();
  readonly jobEvents = new Emitter<JobRequest>();
  readonly offerEvents = new Emitter<Offer>();
  readonly paymentEvents = new Emitter<Payment>();
  readonly sosEvents = new Emitter<SosAlert>();
  readonly disputeEvents = new Emitter<Dispute>();
  readonly supportEvents = new Emitter<SupportTicket>();
  readonly verificationEvents = new Emitter<VerificationSession | undefined>();
  readonly chatEvents = new Emitter<string>(); // emits the jobId whose chat changed

  constructor() {
    this.seed();
  }

  private seed(): void {
    const now = Date.now();

    this.users = {
      'user-ada': {
        id: 'user-ada',
        displayName: 'Adaeze Obi',
        phoneE164: '+2348012345678',
        email: 'ada@example.com',
        countryCode: 'NG',
        preferredLanguage: 'en',
        activeMode: 'customer',
        customerVerification: 'verified',
        providerVerification: 'verified',
        trustLevel: 'trusted',
        referralCode: 'ADA-7K2',
        createdAt: daysFrom(now, -120),
      },
      // Unverified persona for the verification-gating demos.
      'user-chidi': {
        id: 'user-chidi',
        displayName: 'Chidi Eze',
        phoneE164: '+2348098765432',
        countryCode: 'NG',
        preferredLanguage: 'pcm',
        activeMode: 'customer',
        customerVerification: 'unverified',
        providerVerification: 'unverified',
        trustLevel: 'new',
        createdAt: daysFrom(now, -2),
      },
    };

    this.providers = {
      'provider-musa': {
        userId: 'provider-musa',
        displayName: 'Musa Bello',
        kind: 'individual',
        serviceCategoryIds: ['errands_delivery', 'food_pickup'],
        serviceAreaIds: ['lagos-lekki', 'lagos-vi'],
        rating: 4.7,
        completedJobs: 312,
        cancellationRate: 0.02,
        avgResponseTimeSeconds: 95,
        online: true,
        verificationStatus: 'verified',
        vehicleType: 'motorcycle',
      },
      'provider-ngozi': {
        userId: 'provider-ngozi',
        displayName: 'Ngozi Adeyemi',
        kind: 'individual',
        serviceCategoryIds: ['moving', 'shopping'],
        serviceAreaIds: ['lagos-lekki'],
        rating: 4.9,
        completedJobs: 540,
        cancellationRate: 0.01,
        avgResponseTimeSeconds: 60,
        online: true,
        verificationStatus: 'verified',
        vehicleType: 'van',
      },
      // Suspended provider — authors the expired offer on req-1.
      'provider-tunde': {
        userId: 'provider-tunde',
        displayName: 'Tunde Bakare',
        kind: 'individual',
        serviceCategoryIds: ['errands_delivery'],
        serviceAreaIds: ['lagos-ikeja'],
        rating: 3.8,
        completedJobs: 44,
        cancellationRate: 0.18,
        avgResponseTimeSeconds: 420,
        online: false,
        verificationStatus: 'suspended',
        vehicleType: 'bicycle',
      },
      'provider-swift': {
        userId: 'provider-swift',
        displayName: 'SwiftErrands Ltd',
        businessName: 'SwiftErrands Ltd',
        kind: 'business',
        serviceCategoryIds: ['errands_delivery', 'document_delivery'],
        serviceAreaIds: ['lagos-lekki', 'lagos-vi', 'lagos-ikoyi'],
        rating: 4.5,
        completedJobs: 1820,
        cancellationRate: 0.03,
        avgResponseTimeSeconds: 130,
        online: true,
        verificationStatus: 'verified',
        vehicleType: 'car',
      },
      'provider-kwame': {
        userId: 'provider-kwame',
        displayName: 'Kwame Asante',
        kind: 'individual',
        serviceCategoryIds: ['errands_delivery'],
        serviceAreaIds: ['accra-osu'],
        rating: 4.6,
        completedJobs: 210,
        cancellationRate: 0.04,
        avgResponseTimeSeconds: 110,
        online: true,
        verificationStatus: 'expired',
        vehicleType: 'motorcycle',
      },
    };

    const category = (id: string, labelKey: string, iconKey: string, allowsCustom = false): ServiceCategory => ({
      id,
      labelKey,
      iconKey,
      allowsCustom,
      offerTtlSeconds: 600,
      maxCounterRounds: 5,
    });
    this.categories = [
      category('errands_delivery', 'catErrandsDelivery', 'package'),
      category('shopping', 'catShopping', 'cart'),
      category('cleaning_laundry', 'catCleaningLaundry', 'sparkles'),
      category('moving', 'catMoving', 'truck'),
      category('repairs', 'catRepairs', 'wrench'),
      category('personal_assistance', 'catPersonalAssistance', 'person'),
      category('document_delivery', 'catDocumentDelivery', 'document'),
      category('food_pickup', 'catFoodPickup', 'food'),
      category('transportation', 'catTransportation', 'car'),
      category('tech_business', 'catTechBusiness', 'laptop'),
      category('event_assistance', 'catEventAssistance', 'calendar'),
      category('custom', 'catCustom', 'magic', true),
    ];

    this.countryPacks = {
      NG: {
        countryCode: 'NG',
        status: 'live',
        currencyCode: 'NGN',
        supportedLanguages: ['en', 'pcm'],
        defaultLanguage: 'en',
        launchCities: ['Lagos', 'Abuja', 'Port Harcourt'],
        emergencyNumbers: [
          { labelKey: 'emergencyPolice', number: '112' },
          { labelKey: 'emergencyAmbulance', number: '112' },
        ],
        offerTtlSeconds: 600,
        maxNegotiationRounds: 5,
        minWithdrawal: { amountMinor: 100000, currency: 'NGN' },
      },
      KE: {
        countryCode: 'KE',
        status: 'beta',
        currencyCode: 'KES',
        supportedLanguages: ['en'],
        defaultLanguage: 'en',
        launchCities: ['Nairobi'],
        emergencyNumbers: [{ labelKey: 'emergencyPolice', number: '999' }],
        offerTtlSeconds: 600,
        maxNegotiationRounds: 5,
        minWithdrawal: { amountMinor: 20000, currency: 'KES' },
      },
      GH: {
        countryCode: 'GH',
        status: 'beta',
        currencyCode: 'GHS',
        supportedLanguages: ['en'],
        defaultLanguage: 'en',
        launchCities: ['Accra'],
        emergencyNumbers: [{ labelKey: 'emergencyPolice', number: '191' }],
        offerTtlSeconds: 600,
        maxNegotiationRounds: 5,
        minWithdrawal: { amountMinor: 5000, currency: 'GHS' },
      },
      ZA: {
        countryCode: 'ZA',
        status: 'beta',
        currencyCode: 'ZAR',
        supportedLanguages: ['en'],
        defaultLanguage: 'en',
        launchCities: ['Johannesburg'],
        emergencyNumbers: [{ labelKey: 'emergencyPolice', number: '10111' }],
        offerTtlSeconds: 600,
        maxNegotiationRounds: 5,
      },
      UG: {
        countryCode: 'UG',
        status: 'beta',
        currencyCode: 'UGX',
        supportedLanguages: ['en'],
        defaultLanguage: 'en',
        launchCities: ['Kampala'],
        emergencyNumbers: [{ labelKey: 'emergencyPolice', number: '999' }],
        offerTtlSeconds: 600,
        maxNegotiationRounds: 5,
      },
      US: {
        countryCode: 'US',
        status: 'disabled',
        currencyCode: 'USD',
        supportedLanguages: ['en'],
        defaultLanguage: 'en',
        launchCities: [],
        emergencyNumbers: [{ labelKey: 'emergencyGeneral', number: '911' }],
        offerTtlSeconds: 600,
        maxNegotiationRounds: 5,
        minWithdrawal: { amountMinor: 1000, currency: 'USD' },
      },
    };

    const home: PlaceRefSeed = {
      label: 'Home — Admiralty Way',
      point: { latitude: 6.4311, longitude: 3.4359 },
    };

    this.requests = {
      // Collecting offers: one pending, one countered (round 2), one expired.
      'req-1': {
        id: 'req-1',
        customerId: 'user-ada',
        categoryId: 'shopping',
        isCustomCategory: false,
        description: 'Buy groceries from Spar Lekki — list attached as photo.',
        mediaPaths: ['mock://media/list1.jpg'],
        pickup: {
          label: 'Spar, Lekki Phase 1',
          point: { latitude: 6.4474, longitude: 3.4723 },
          landmarkNote: 'Opposite the roundabout, blue gate',
        },
        destination: { ...home },
        urgency: 'standard',
        status: 'negotiating',
        createdAt: minutesFrom(now, -12),
        preferredPrice: { amountMinor: 500000, currency: 'NGN' },
        itemFloat: { amountMinor: 1500000, currency: 'NGN' },
        expiresAt: hoursFrom(now, 4),
      },
      // In progress with handover PIN + chat + tracking.
      'req-2': {
        id: 'req-2',
        customerId: 'user-ada',
        categoryId: 'food_pickup',
        isCustomCategory: false,
        description: 'Pick up my order from Chicken Republic, Admiralty.',
        mediaPaths: [],
        pickup: {
          label: 'Chicken Republic, Admiralty Way',
          point: { latitude: 6.4281, longitude: 3.4219 },
        },
        destination: { ...home },
        urgency: 'urgent',
        status: 'in_progress',
        createdAt: minutesFrom(now, -40),
        agreedPrice: { amountMinor: 320000, currency: 'NGN' },
        agreedBreakdown: simulateQuote(
          { amountMinor: 320000, currency: 'NGN' },
          { estimatedGatewayFee: { amountMinor: 4800, currency: 'NGN' } },
        ),
        providerId: 'provider-musa',
        handoverPin: '4281',
      },
      // Disputed (disp-1 is in review against it).
      'req-3': {
        id: 'req-3',
        customerId: 'user-ada',
        categoryId: 'document_delivery',
        isCustomCategory: false,
        description: 'Deliver signed documents to a law office on Ikoyi.',
        mediaPaths: [],
        pickup: { ...home },
        destination: {
          label: 'Law office, Bourdillon Rd, Ikoyi',
          point: { latitude: 6.4527, longitude: 3.432 },
        },
        urgency: 'standard',
        status: 'disputed',
        createdAt: hoursFrom(now, -27),
        agreedPrice: { amountMinor: 450000, currency: 'NGN' },
        agreedBreakdown: simulateQuote(
          { amountMinor: 450000, currency: 'NGN' },
          { estimatedGatewayFee: { amountMinor: 6750, currency: 'NGN' } },
        ),
        providerId: 'provider-swift',
        declaredValue: { amountMinor: 5000000, currency: 'NGN' },
      },
      // Confirmed 2h ago — rateable, chat still inside the 24h window.
      'req-4': {
        id: 'req-4',
        customerId: 'user-ada',
        categoryId: 'cleaning_laundry',
        isCustomCategory: false,
        description: 'Deep clean a 2-bedroom apartment.',
        mediaPaths: [],
        pickup: { ...home },
        urgency: 'flexible',
        status: 'confirmed',
        createdAt: daysFrom(now, -6),
        agreedPrice: { amountMinor: 2500000, currency: 'NGN' },
        agreedBreakdown: simulateQuote(
          { amountMinor: 2500000, currency: 'NGN' },
          {
            estimatedGatewayFee: { amountMinor: 37500, currency: 'NGN' },
            tip: { amountMinor: 200000, currency: 'NGN' },
          },
        ),
        providerId: 'provider-ngozi',
      },
      // Draft (custom category, scheduled).
      'req-5': {
        id: 'req-5',
        customerId: 'user-ada',
        categoryId: 'custom',
        isCustomCategory: true,
        description: 'Help me queue for passport photos and print forms.',
        mediaPaths: [],
        pickup: { label: 'Ikoyi Passport Office' },
        urgency: 'standard',
        status: 'draft',
        createdAt: minutesFrom(now, -55),
        preferredPrice: { amountMinor: 700000, currency: 'NGN' },
        scheduledAt: hoursFrom(now, 26),
      },
      // Awaiting payment inside the 15-minute TTL.
      'req-6': {
        id: 'req-6',
        customerId: 'user-ada',
        categoryId: 'errands_delivery',
        isCustomCategory: false,
        description: 'Collect a parcel from a vendor in Yaba.',
        mediaPaths: [],
        pickup: {
          label: 'Yaba market stall 14',
          point: { latitude: 6.5095, longitude: 3.3711 },
        },
        destination: { label: 'Home — Admiralty Way' },
        urgency: 'standard',
        status: 'payment_pending',
        createdAt: minutesFrom(now, -25),
        agreedPrice: { amountMinor: 400000, currency: 'NGN' },
        agreedBreakdown: simulateQuote(
          { amountMinor: 400000, currency: 'NGN' },
          { estimatedGatewayFee: { amountMinor: 6000, currency: 'NGN' } },
        ),
        providerId: 'provider-swift',
        expiresAt: minutesFrom(now, 9),
      },
      // Freshly agreed — ready for the payment step.
      'req-7': {
        id: 'req-7',
        customerId: 'user-ada',
        categoryId: 'moving',
        isCustomCategory: false,
        description: 'Move a sofa from Lekki to Yaba.',
        mediaPaths: [],
        pickup: {
          label: 'Lekki Phase 1',
          point: { latitude: 6.4474, longitude: 3.4723 },
        },
        destination: {
          label: 'Yaba, near the market',
          point: { latitude: 6.5095, longitude: 3.3711 },
        },
        urgency: 'standard',
        status: 'agreed',
        createdAt: hoursFrom(now, -3),
        agreedPrice: { amountMinor: 750000, currency: 'NGN' },
        agreedBreakdown: simulateQuote(
          { amountMinor: 750000, currency: 'NGN' },
          { estimatedGatewayFee: { amountMinor: 11250, currency: 'NGN' } },
        ),
        providerId: 'provider-ngozi',
        handoverPin: '4281',
      },
      // Paid and held — chat window just opened.
      'req-8': {
        id: 'req-8',
        customerId: 'user-ada',
        categoryId: 'personal_assistance',
        isCustomCategory: false,
        description: 'Wait for a furniture delivery and sign for it.',
        mediaPaths: [],
        pickup: { ...home },
        urgency: 'standard',
        status: 'paid_held',
        createdAt: hoursFrom(now, -2),
        agreedPrice: { amountMinor: 600000, currency: 'NGN' },
        agreedBreakdown: simulateQuote(
          { amountMinor: 600000, currency: 'NGN' },
          { estimatedGatewayFee: { amountMinor: 9000, currency: 'NGN' } },
        ),
        providerId: 'provider-musa',
        handoverPin: '4281',
      },
    };

    this.offers = {
      'req-1': [
        {
          id: 'offer-1a',
          requestId: 'req-1',
          providerId: 'provider-musa',
          providerName: 'Musa Bello',
          providerRating: 4.7,
          providerTrustLevel: 'verified',
          amount: { amountMinor: 650000, currency: 'NGN' },
          status: 'pending',
          round: 1,
          createdAt: minutesFrom(now, -8),
          message: 'I dey near Spar now, I fit do am quick.',
          distanceMeters: 900,
          payoutEstimate: simulateQuote(
            { amountMinor: 650000, currency: 'NGN' },
            { estimatedGatewayFee: { amountMinor: 9750, currency: 'NGN' } },
          ),
          expiresAt: minutesFrom(now, 9),
        },
        {
          id: 'offer-1b',
          requestId: 'req-1',
          providerId: 'provider-swift',
          providerName: 'SwiftErrands Ltd',
          providerRating: 4.5,
          providerTrustLevel: 'elite',
          amount: { amountMinor: 580000, currency: 'NGN' },
          status: 'countered',
          round: 2,
          createdAt: minutesFrom(now, -5),
          distanceMeters: 2400,
          payoutEstimate: simulateQuote(
            { amountMinor: 580000, currency: 'NGN' },
            { estimatedGatewayFee: { amountMinor: 8700, currency: 'NGN' } },
          ),
          expiresAt: minutesFrom(now, 6),
        },
        {
          id: 'offer-1c',
          requestId: 'req-1',
          providerId: 'provider-tunde',
          providerName: 'Tunde Bakare',
          providerRating: 3.8,
          providerTrustLevel: 'new',
          amount: { amountMinor: 500000, currency: 'NGN' },
          status: 'expired',
          round: 1,
          createdAt: minutesFrom(now, -11),
          distanceMeters: 5100,
          expiresAt: minutesFrom(now, -1),
        },
      ],
    };

    this.payments = {
      'pay-2': {
        id: 'pay-2',
        jobId: 'req-2',
        amount: { amountMinor: 320000, currency: 'NGN' },
        method: 'card',
        status: 'held',
        createdAt: minutesFrom(now, -35),
        gatewayReference: 'FLW-MOCK-pay-2',
        paidAt: minutesFrom(now, -34),
      },
      'pay-3': {
        id: 'pay-3',
        jobId: 'req-3',
        amount: { amountMinor: 450000, currency: 'NGN' },
        method: 'bank_transfer',
        status: 'held',
        createdAt: hoursFrom(now, -26),
        gatewayReference: 'FLW-MOCK-pay-3',
        paidAt: hoursFrom(now, -26),
      },
      'pay-4': {
        id: 'pay-4',
        jobId: 'req-4',
        amount: { amountMinor: 2500000, currency: 'NGN' },
        method: 'card',
        status: 'held',
        createdAt: daysFrom(now, -6),
        gatewayReference: 'FLW-MOCK-pay-4',
        paidAt: daysFrom(now, -6),
      },
      'pay-8': {
        id: 'pay-8',
        jobId: 'req-8',
        amount: { amountMinor: 600000, currency: 'NGN' },
        method: 'ussd',
        status: 'held',
        createdAt: hoursFrom(now, -1),
        gatewayReference: 'FLW-MOCK-pay-8',
        paidAt: hoursFrom(now, -1),
      },
    };
    this.paymentByJob = {
      'req-2': 'pay-2',
      'req-3': 'pay-3',
      'req-4': 'pay-4',
      'req-8': 'pay-8',
    };

    this.jobConfirmedAt = { 'req-4': hoursFrom(now, -2) };

    this.chats = {
      'req-2': [
        {
          id: 'msg-1',
          jobId: 'req-2',
          senderId: 'user-ada',
          type: 'text',
          text: 'Please ask them to add extra pepper sauce.',
          createdAt: minutesFrom(now, -30),
          readAt: minutesFrom(now, -29),
        },
        {
          id: 'msg-2',
          jobId: 'req-2',
          senderId: 'provider-musa',
          type: 'text',
          text: 'Done. I don pick the order, I dey come now.',
          createdAt: minutesFrom(now, -12),
        },
        {
          id: 'msg-3',
          jobId: 'req-2',
          senderId: 'system',
          type: 'system',
          text: 'Provider is on the way',
          createdAt: minutesFrom(now, -12),
        },
      ],
      'req-8': [
        {
          id: 'msg-8-1',
          jobId: 'req-8',
          senderId: 'system',
          type: 'system',
          text: 'Payment confirmed — chat is now open',
          createdAt: hoursFrom(now, -1),
        },
      ],
    };

    this.wallets = {
      'user-ada': {
        available: { amountMinor: 1845000, currency: 'NGN' },
        pending: { amountMinor: 320000, currency: 'NGN' },
        lifetimeEarned: { amountMinor: 8420000, currency: 'NGN' },
      },
    };

    this.walletTransactions = {
      'user-ada': [
        {
          id: 'txn-1',
          kind: 'payout',
          status: 'completed',
          amount: { amountMinor: 2175000, currency: 'NGN' },
          referenceId: 'req-4',
          descriptionKey: 'txnPayoutCleaning',
          createdAt: daysFrom(now, -5),
        },
        {
          id: 'txn-2',
          kind: 'tip',
          status: 'completed',
          amount: { amountMinor: 200000, currency: 'NGN' },
          referenceId: 'req-4',
          descriptionKey: 'txnTip',
          createdAt: daysFrom(now, -5),
        },
        {
          id: 'txn-3',
          kind: 'referral',
          status: 'completed',
          amount: { amountMinor: 54300, currency: 'NGN' },
          descriptionKey: 'txnReferral',
          createdAt: daysFrom(now, -3),
        },
        {
          id: 'txn-4',
          kind: 'refund',
          status: 'completed',
          amount: { amountMinor: 150000, currency: 'NGN' },
          descriptionKey: 'txnRefundItemFloat',
          createdAt: daysFrom(now, -2),
        },
      ],
    };

    this.referrals = {
      'user-ada': {
        code: 'ADA-7K2',
        shareLink: 'https://suskii.app/r/ADA-7K2',
        invitedCount: 14,
        activeReferrals: 5,
        earnedTotal: { amountMinor: 1245000, currency: 'NGN' },
        holding: { amountMinor: 105000, currency: 'NGN' },
        available: { amountMinor: 1140000, currency: 'NGN' },
      },
    };

    this.promos = {
      WELCOME10: {
        code: 'WELCOME10',
        titleKey: 'promoWelcomeTitle',
        descriptionKey: 'promoWelcomeBody',
        percentOff: 10,
        maxDiscount: { amountMinor: 200000, currency: 'NGN' },
        expiresAt: daysFrom(now, 30),
        redeemed: false,
      },
      FESTIVE20: {
        code: 'FESTIVE20',
        titleKey: 'promoFestiveTitle',
        descriptionKey: 'promoFestiveBody',
        percentOff: 20,
        maxDiscount: { amountMinor: 500000, currency: 'NGN' },
        expiresAt: daysFrom(now, -10),
        redeemed: false,
      },
    };

    this.disputes = {
      'req-3': {
        id: 'disp-1',
        jobId: 'req-3',
        openedBy: 'user-ada',
        reasonKey: 'disputeReasonNotDelivered',
        status: 'in_review',
        createdAt: hoursFrom(now, -2),
        slaDeadline: hoursFrom(now, 22),
      },
    };

    this.tickets = {
      'ticket-1': {
        id: 'ticket-1',
        subject: 'Where is my refund?',
        status: 'open',
        createdAt: hoursFrom(now, -5),
        messages: [
          {
            id: 'tmsg-1',
            body: 'My card was charged but the job was cancelled.',
            fromUser: true,
            aiTriage: false,
            createdAt: hoursFrom(now, -5),
          },
          {
            id: 'tmsg-2',
            body:
              'I can see a pending refund on your cancelled job. Refunds to ' +
              'cards take 3–5 business days. I have flagged this for a ' +
              'human agent to confirm.',
            fromUser: false,
            aiTriage: true,
            createdAt: minutesFrom(now, -295),
          },
        ],
      },
    };

    this.notificationPrefs = {};
    this.trustedContacts = {
      'user-ada': [
        { id: 'tc-1', name: 'Ngozi Obi', phoneE164: '+2347012345678' },
      ],
    };

    this.ratings = {};
    this.sosAlerts = {};

    this.notifications = [
      {
        id: 'ntf-1',
        kind: 'offer',
        title: 'New offer from Musa Bello',
        body: '₦6,500.00 for your shopping request',
        read: false,
        createdAt: minutesFrom(now, -8),
        deeplink: '/customer/requests/req-1/offers',
      },
      {
        id: 'ntf-2',
        kind: 'job',
        title: 'Provider on the way',
        body: 'Your food pickup is en route',
        read: true,
        createdAt: minutesFrom(now, -12),
        deeplink: '/customer/requests/req-2/track',
      },
    ];

    this.verificationSessions = {
      'user-ada': {
        id: 'vs-user-ada',
        kind: 'customer_facial',
        status: 'verified',
        updatedAt: daysFrom(now, -100),
      },
    };
  }
}

/** Seed helper type: a PlaceRef literal before it is fully formed. */
interface PlaceRefSeed {
  label: string;
  point?: { latitude: number; longitude: number };
  landmarkNote?: string;
}

/** Fresh, independently-seeded database (tests and demo resets). */
export function createMockDatabase(): MockDatabase {
  return new MockDatabase();
}

/** The shared instance the mock repositories serve. */
export const db = createMockDatabase();
