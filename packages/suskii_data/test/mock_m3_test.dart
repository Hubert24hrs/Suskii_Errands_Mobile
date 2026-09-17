import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_data/suskii_data.dart';
import 'package:suskii_domain/suskii_domain.dart';
import 'package:test/test.dart';

void main() {
  late MockDatabase db;
  late MockBehavior behavior;

  setUp(() {
    db = MockDatabase();
    behavior = MockBehavior(latency: Duration.zero);
  });

  Matcher expectCode(String code) =>
      isA<AppError>().having((AppError e) => e.code, 'code', code);

  group('publish gate (review 2.14 / C.3)', () {
    test('unverified customers can create drafts', () async {
      behavior.currentUserId = 'user-chidi';
      final repo = MockRequestRepository(db, behavior);
      final draft = await repo.createRequest(
        const CreateRequestInput(
          categoryId: 'shopping',
          description: 'Buy groceries.',
          pickup: PlaceRef(label: 'Spar Lekki'),
        ),
        idempotencyKey: newIdempotencyKey(),
      );
      expect(draft.status, JobStatus.draft);
      expect(draft.expiresAt, isNull);
    });

    test(
      'publish is blocked with ERR_VERIFICATION_REQUIRED when unverified',
      () async {
        behavior.currentUserId = 'user-chidi';
        final repo = MockRequestRepository(db, behavior);
        final draft = await repo.createRequest(
          const CreateRequestInput(
            categoryId: 'shopping',
            description: 'Buy groceries.',
            pickup: PlaceRef(label: 'Spar Lekki'),
          ),
          idempotencyKey: newIdempotencyKey(),
        );
        expect(
          () => repo.publishRequest(
            draft.id,
            idempotencyKey: newIdempotencyKey(),
          ),
          throwsA(expectCode(ErrorCodes.verificationRequired)),
        );
      },
    );

    test('publish flips DRAFT → PUBLISHED for verified customers', () async {
      final repo = MockRequestRepository(db, behavior); // user-ada: verified
      final draft = await repo.createRequest(
        const CreateRequestInput(
          categoryId: 'shopping',
          description: 'Buy groceries.',
          pickup: PlaceRef(label: 'Spar Lekki'),
        ),
        idempotencyKey: newIdempotencyKey(),
      );
      final published = await repo.publishRequest(
        draft.id,
        idempotencyKey: newIdempotencyKey(),
      );
      expect(published.status, JobStatus.published);
      expect(published.expiresAt, isNotNull);
      expect(db.requests[draft.id]!.status, JobStatus.published);
    });

    test('publishing a non-draft is rejected', () async {
      final repo = MockRequestRepository(db, behavior);
      expect(
        () => repo.publishRequest(
          'req-1', // negotiating
          idempotencyKey: newIdempotencyKey(),
        ),
        throwsA(expectCode(ErrorCodes.permissionDenied)),
      );
    });
  });

  group('idempotency (S-10 / review M3.8)', () {
    test('same key + same payload replays without re-executing', () async {
      final repo = MockOfferRepository(db, behavior);
      final key = newIdempotencyKey();
      final first = await repo.counterOffer(
        offerId: 'offer-1a',
        amount: const Money(600000, 'NGN'),
        idempotencyKey: key,
      );
      final replayed = await repo.counterOffer(
        offerId: 'offer-1a',
        amount: const Money(600000, 'NGN'),
        idempotencyKey: key,
      );
      // Replay returns the stored result — the round did not advance twice.
      expect(replayed.round, first.round);
      expect(replayed.expiresAt, first.expiresAt);
    });

    test(
      'same key + different payload throws ERR_IDEMPOTENCY_KEY_REUSED',
      () async {
        final repo = MockOfferRepository(db, behavior);
        final key = newIdempotencyKey();
        await repo.counterOffer(
          offerId: 'offer-1a',
          amount: const Money(600000, 'NGN'),
          idempotencyKey: key,
        );
        expect(
          () => repo.counterOffer(
            offerId: 'offer-1a',
            amount: const Money(700000, 'NGN'),
            idempotencyKey: key,
          ),
          throwsA(expectCode(ErrorCodes.idempotencyKeyReused)),
        );
      },
    );
  });

  group('handover PIN (review M3.9)', () {
    test('correct PIN verifies; wrong PIN spends an attempt', () async {
      final repo = MockJobProgressRepository(db, behavior);
      expect(
        await repo.verifyHandoverPin(
          'req-3',
          '4281',
          idempotencyKey: newIdempotencyKey(),
        ),
        isTrue,
      );
      expect(
        await repo.verifyHandoverPin(
          'req-2',
          '0000',
          idempotencyKey: newIdempotencyKey(),
        ),
        isFalse,
      );
    });

    test(
      'retrying the same intent key replays without spending an attempt',
      () async {
        final repo = MockJobProgressRepository(db, behavior);
        final key = newIdempotencyKey();
        await repo.verifyHandoverPin('req-2', '0000', idempotencyKey: key);
        // Same key + same PIN: replay. Four more DISTINCT intents spend the
        // remaining attempts; the sixth distinct attempt is locked out. If
        // the replay above had spent an attempt, the lockout would hit one
        // call earlier.
        await repo.verifyHandoverPin('req-2', '0000', idempotencyKey: key);
        for (var i = 0; i < 4; i++) {
          await repo.verifyHandoverPin(
            'req-2',
            '0000',
            idempotencyKey: newIdempotencyKey(),
          );
        }
        expect(
          () => repo.verifyHandoverPin(
            'req-2',
            '0000',
            idempotencyKey: newIdempotencyKey(),
          ),
          throwsA(expectCode(ErrorCodes.permissionDenied)),
        );
        // The replay path still works after the lockout.
        expect(
          await repo.verifyHandoverPin('req-2', '0000', idempotencyKey: key),
          isFalse,
        );
      },
    );
  });

  group('offer realtime simulation', () {
    Future<JobRequest> publishFresh() async {
      final requests = MockRequestRepository(db, behavior);
      final draft = await requests.createRequest(
        const CreateRequestInput(
          categoryId: 'errands_delivery',
          description: 'Deliver a parcel.',
          pickup: PlaceRef(label: 'VI'),
          preferredPrice: Money(400000, 'NGN'),
        ),
        idempotencyKey: newIdempotencyKey(),
      );
      return requests.publishRequest(
        draft.id,
        idempotencyKey: newIdempotencyKey(),
      );
    }

    test(
      'offers arrive over time with eta and move request to offersReceived',
      () async {
        final published = await publishFresh();
        final repo = MockOfferRepository(db, behavior);
        final board = await repo
            .watchOffers(published.id)
            .firstWhere((List<Offer> offers) => offers.length >= 2)
            .timeout(const Duration(seconds: 20));
        expect(board.length, greaterThanOrEqualTo(2));
        expect(board.every((Offer o) => o.etaMinutes != null), isTrue);
        expect(board.every((Offer o) => o.distanceMeters != null), isTrue);
        expect(board.every((Offer o) => o.expiresAt != null), isTrue);
        expect(db.requests[published.id]!.status, JobStatus.offersReceived);
      },
    );

    test('offers expire when the TTL passes (server clock)', () async {
      behavior.offerTtlOverride = const Duration(seconds: 1);
      final published = await publishFresh();
      final repo = MockOfferRepository(db, behavior);
      final board = await repo
          .watchOffers(published.id)
          .firstWhere(
            (List<Offer> offers) =>
                offers.any((Offer o) => o.status == OfferStatus.expired),
          )
          .timeout(const Duration(seconds: 25));
      final expired = board.firstWhere(
        (Offer o) => o.status == OfferStatus.expired,
      );
      expect(
        expired.expiresAt!.isBefore(
          DateTime.now().toUtc().add(
            behavior.serverClockSkew + const Duration(seconds: 1),
          ),
        ),
        isTrue,
      );
    });

    test('accept locks siblings and agrees the job atomically', () async {
      final published = await publishFresh();
      final repo = MockOfferRepository(db, behavior);
      final board = await repo
          .watchOffers(published.id)
          .firstWhere((List<Offer> offers) => offers.length >= 2)
          .timeout(const Duration(seconds: 20));
      final accepted = await repo.acceptOffer(
        board.first.id,
        idempotencyKey: newIdempotencyKey(),
      );
      expect(accepted.status, OfferStatus.accepted);
      final request = db.requests[published.id]!;
      expect(request.status, JobStatus.agreed);
      expect(request.agreedPrice, accepted.amount);
      expect(request.agreedBreakdown, isNotNull);
      final siblings = db.offers[published.id]!.where(
        (Offer o) => o.id != accepted.id,
      );
      expect(
        siblings.every((Offer o) => o.status == OfferStatus.expired),
        isTrue,
      );
    });
  });

  group('per-category negotiation config', () {
    test('counter rounds are capped per category', () async {
      final idx = db.categories.indexWhere((c) => c.id == 'shopping');
      db.categories[idx] = db.categories[idx].copyWith(maxCounterRounds: 2);
      final repo = MockOfferRepository(db, behavior);
      // offer-1b (shopping) is already at round 2 → at the cap.
      expect(
        () => repo.counterOffer(
          offerId: 'offer-1b',
          amount: const Money(560000, 'NGN'),
          idempotencyKey: newIdempotencyKey(),
        ),
        throwsA(expectCode(ErrorCodes.offerRoundsExhausted)),
      );
    });

    test('offer TTL comes from the category', () async {
      final idx = db.categories.indexWhere((c) => c.id == 'shopping');
      db.categories[idx] = db.categories[idx].copyWith(offerTtlSeconds: 2);
      final repo = MockOfferRepository(db, behavior);
      final countered = await repo.counterOffer(
        offerId: 'offer-1a',
        amount: const Money(600000, 'NGN'),
        idempotencyKey: newIdempotencyKey(),
      );
      final expected = DateTime.now()
          .toUtc()
          .add(behavior.serverClockSkew)
          .add(const Duration(seconds: 2));
      expect(
        countered.expiresAt!.difference(expected).inSeconds.abs(),
        lessThan(2),
      );
    });

    test('provider can withdraw a pending offer', () async {
      final repo = MockOfferRepository(db, behavior);
      final withdrawn = await repo.withdrawOffer(
        'offer-1a',
        idempotencyKey: newIdempotencyKey(),
      );
      expect(withdrawn.status, OfferStatus.withdrawn);
      expect(
        () =>
            repo.withdrawOffer('offer-1a', idempotencyKey: newIdempotencyKey()),
        throwsA(expectCode(ErrorCodes.permissionDenied)),
      );
    });
  });

  group('price intelligence', () {
    test('returns a plausible per-category band', () async {
      final repo = MockCatalogRepository(db, behavior);
      final band = await repo.getPriceBand(categoryId: 'cleaning_laundry');
      expect(band.p25 < band.p50, isTrue);
      expect(band.p50 < band.p75, isTrue);
      expect(band.p50.currencyCode, 'NGN');
      expect(band.sampleSize, greaterThan(0));
      expect(band.confidence, PriceBandConfidence.medium);
    });

    test('unknown category gets a low-confidence fallback band', () async {
      final repo = MockCatalogRepository(db, behavior);
      final band = await repo.getPriceBand(categoryId: 'custom');
      expect(band.confidence, PriceBandConfidence.low);
    });
  });

  group('bootstrap server time', () {
    test('serverTime carries the simulated skew vs device time', () async {
      final repo = MockBootstrapRepository(db, behavior);
      final boot = await repo.getBootstrap();
      final skew = boot.serverTime.difference(DateTime.now().toUtc());
      expect(skew.inSeconds, closeTo(behavior.serverClockSkew.inSeconds, 2));
    });
  });

  group('concierge slot filling', () {
    Future<List<ConciergeMessage>> messagesAfter(
      MockConciergeRepository repo,
      String conversationId,
    ) => repo.watchMessages(conversationId).first;

    Future<ConciergeConversation> startAndDescribe(
      MockConciergeRepository repo,
      String text,
    ) async {
      final conversation = await repo.startConversation(
        idempotencyKey: newIdempotencyKey(),
      );
      await repo
          .sendMessage(
            conversation.id,
            text,
            idempotencyKey: newIdempotencyKey(),
          )
          .drain<void>();
      return conversation;
    }

    test(
      'the underlying draft request exists from the first slot (M3.10)',
      () async {
        final repo = MockConciergeRepository(db, behavior);
        final conversation = await startAndDescribe(
          repo,
          'I need someone to clean my apartment',
        );
        final messages = await messagesAfter(repo, conversation.id);
        final draft = messages.last.structuredDraft!;
        expect(draft.requestId, isNotNull);
        final stored = db.requests[draft.requestId]!;
        expect(stored.status, JobStatus.draft);
        expect(stored.categoryId, 'cleaning_laundry');
        expect(stored.description, contains('clean'));
      },
    );

    test(
      'three turns fill the draft, then the publish card publishes',
      () async {
        final repo = MockConciergeRepository(db, behavior);
        final conversation = await startAndDescribe(
          repo,
          'I need someone to clean my apartment',
        );
        final id = conversation.id;

        var messages = await messagesAfter(repo, id);
        var draft = messages.last.structuredDraft!;
        expect(messages.last.role, ConciergeRole.assistant);
        expect(draft.categoryId, 'cleaning_laundry');
        expect(draft.description, contains('clean'));
        expect(draft.missingSlots, <String>['pickup', 'preferredPrice']);
        expect(messages.last.proposedAction, ConciergeProposedAction.none);

        await repo
            .sendMessage(
              id,
              'Lekki Phase 1',
              idempotencyKey: newIdempotencyKey(),
            )
            .drain<void>();
        messages = await messagesAfter(repo, id);
        draft = messages.last.structuredDraft!;
        expect(draft.pickup!.label, 'Lekki Phase 1');
        expect(draft.missingSlots, <String>['preferredPrice']);
        // The half-finished draft request tracks the slots so far (CU-01).
        expect(db.requests[draft.requestId]!.pickup.label, 'Lekki Phase 1');

        await repo
            .sendMessage(
              id,
              'I can pay 5000',
              idempotencyKey: newIdempotencyKey(),
            )
            .drain<void>();
        messages = await messagesAfter(repo, id);
        draft = messages.last.structuredDraft!;
        expect(draft.preferredPrice, const Money(500000, 'NGN'));
        expect(draft.missingSlots, isEmpty);
        expect(
          messages.last.proposedAction,
          ConciergeProposedAction.showPublishCard,
        );

        // The publish card calls publishRequest on the server-side draft —
        // the concierge itself holds no publish capability (M3.1).
        // user-ada is verified.
        final requests = MockRequestRepository(db, behavior);
        final published = await requests.publishRequest(
          draft.requestId!,
          idempotencyKey: newIdempotencyKey(),
        );
        expect(published.status, JobStatus.published);
        expect(published.categoryId, 'cleaning_laundry');
        expect(published.preferredPrice, const Money(500000, 'NGN'));
        expect(published.pickup.label, 'Lekki Phase 1');
      },
    );

    test('publishing a concierge draft is verification-gated', () async {
      behavior.currentUserId = 'user-chidi';
      final repo = MockConciergeRepository(db, behavior);
      final conversation = await startAndDescribe(
        repo,
        'Deliver a package for me',
      );
      final id = conversation.id;
      await repo
          .sendMessage(id, 'Yaba market', idempotencyKey: newIdempotencyKey())
          .drain<void>();
      await repo
          .sendMessage(id, '3000', idempotencyKey: newIdempotencyKey())
          .drain<void>();
      final messages = await messagesAfter(repo, id);
      final draft = messages.last.structuredDraft!;
      expect(
        () => MockRequestRepository(
          db,
          behavior,
        ).publishRequest(draft.requestId!, idempotencyKey: newIdempotencyKey()),
        throwsA(expectCode(ErrorCodes.verificationRequired)),
      );
    });

    test('a fresh conversation has no draft request to publish', () async {
      final repo = MockConciergeRepository(db, behavior);
      final conversation = await repo.startConversation(
        idempotencyKey: newIdempotencyKey(),
      );
      final messages = await messagesAfter(repo, conversation.id);
      expect(messages.last.structuredDraft!.requestId, isNull);
    });

    test(
      'replaying a send with a different message is refused (M3.8)',
      () async {
        final repo = MockConciergeRepository(db, behavior);
        final conversation = await repo.startConversation(
          idempotencyKey: newIdempotencyKey(),
        );
        final key = newIdempotencyKey();
        await repo
            .sendMessage(
              conversation.id,
              'Deliver a parcel',
              idempotencyKey: key,
            )
            .drain<void>();
        expect(
          () => repo
              .sendMessage(
                conversation.id,
                'Buy groceries',
                idempotencyKey: key,
              )
              .drain<void>(),
          throwsA(expectCode(ErrorCodes.idempotencyKeyReused)),
        );
      },
    );

    test('unknown requests classify as custom categories', () async {
      final repo = MockConciergeRepository(db, behavior);
      final conversation = await startAndDescribe(
        repo,
        'Queue at the embassy for me',
      );
      final messages = await messagesAfter(repo, conversation.id);
      expect(messages.last.structuredDraft!.categoryId, 'custom');
      expect(messages.last.structuredDraft!.isCustomCategory, isTrue);
    });
  });

  group('voice concierge (OD-17)', () {
    test('pcm is rejected so the UI falls back to text', () async {
      final adapter = MockVoiceConciergeAdapter(db, behavior);
      expect(
        () => adapter.startSession('conv-1', language: 'pcm'),
        throwsA(expectCode(ErrorCodes.unsupportedLanguage)),
      );
    });

    test('english session connects and starts listening', () async {
      final adapter = MockVoiceConciergeAdapter(db, behavior);
      final session = await adapter.startSession('conv-1');
      expect(session.language, 'en');
      final states = await adapter
          .events(session.sessionId)
          .map((VoiceEvent e) => e.state)
          .toList();
      expect(states, <VoiceSessionState?>[
        VoiceSessionState.connecting,
        VoiceSessionState.listening,
      ]);
    });
  });
}
