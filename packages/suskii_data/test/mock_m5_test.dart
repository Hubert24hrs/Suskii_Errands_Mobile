import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_data/suskii_data.dart';
import 'package:suskii_domain/suskii_domain.dart';
import 'package:test/test.dart';

void main() {
  late MockDatabase db;
  late MockBehavior behavior;

  setUp(() {
    db = MockDatabase();
    behavior = MockBehavior(latency: Duration.zero)
      ..disputeResolveDelay = const Duration(milliseconds: 50)
      ..supportTriageDelay = const Duration(milliseconds: 50);
  });

  Matcher expectCode(String code) =>
      isA<AppError>().having((AppError e) => e.code, 'code', code);

  /// Awaits a closure expected to throw (every throw-expectation is awaited so
  /// later statements — persona switches, timers — cannot race the gated
  /// mock call).
  Future<void> expectThrows(Future<Object?> Function() fn, String code) =>
      expectLater(fn, throwsA(expectCode(code)));

  group('disputes (M5)', () {
    test('seeded dispute on req-3 is listed and watchable', () async {
      final repo = MockDisputeRepository(db, behavior);
      final mine = await repo.getMyDisputes();
      expect(mine, hasLength(1));
      expect(mine.single.id, 'disp-1');
      expect(mine.single.status, DisputeStatus.inReview);
      expect(
        repo.watchDispute('req-3'),
        emits(isA<Dispute>().having((Dispute d) => d.id, 'id', 'disp-1')),
      );
    });

    test(
      'opening a dispute freezes the job, then resolves with a 50% refund',
      () async {
        final repo = MockDisputeRepository(db, behavior);
        final dispute = await repo.openDispute(
          jobId: 'req-2', // enRoute, customer user-ada
          reasonKey: 'disputeReasonNotDelivered',
          idempotencyKey: newIdempotencyKey(),
          details: 'Provider never arrived at the pickup.',
        );
        expect(dispute.status, DisputeStatus.open);
        expect(dispute.slaDeadline, isNotNull);
        expect(db.requests['req-2']!.status, JobStatus.disputed);

        await Future<void>.delayed(const Duration(milliseconds: 200));
        final resolved = db.disputes['req-2']!;
        expect(resolved.status, DisputeStatus.resolved);
        expect(resolved.resolutionNoteKey, 'disputeResolvedPartialRefund');
        // 50% of the agreed ₦3,200.00, decided server-side.
        expect(resolved.refundAmount, const Money(160000, 'NGN'));
        expect(db.requests['req-2']!.status, JobStatus.refunded);
      },
    );

    test('re-opening a disputed job returns the existing dispute', () async {
      final repo = MockDisputeRepository(db, behavior);
      final again = await repo.openDispute(
        jobId: 'req-3', // already disputed (disp-1)
        reasonKey: 'disputeReasonDamaged',
        idempotencyKey: newIdempotencyKey(),
      );
      expect(again.id, 'disp-1');
      expect(db.disputes.length, 1);
    });

    test(
      'only participants can dispute, and only in disputable states',
      () async {
        final repo = MockDisputeRepository(db, behavior);
        await expectThrows(
          () => repo.openDispute(
            jobId: 'req-5', // draft
            reasonKey: 'disputeReasonNotDelivered',
            idempotencyKey: newIdempotencyKey(),
          ),
          ErrorCodes.invalidState,
        );
        behavior.currentUserId = 'user-kofi';
        await expectThrows(
          () => repo.openDispute(
            jobId: 'req-2', // user-ada's job
            reasonKey: 'disputeReasonNotDelivered',
            idempotencyKey: newIdempotencyKey(),
          ),
          ErrorCodes.permissionDenied,
        );
      },
    );

    test('same key replays; same key + different reason is refused', () async {
      final repo = MockDisputeRepository(db, behavior);
      final key = newIdempotencyKey();
      final first = await repo.openDispute(
        jobId: 'req-2',
        reasonKey: 'disputeReasonNotDelivered',
        idempotencyKey: key,
      );
      final replay = await repo.openDispute(
        jobId: 'req-2',
        reasonKey: 'disputeReasonNotDelivered',
        idempotencyKey: key,
      );
      expect(replay.id, first.id);
      await expectThrows(
        () => repo.openDispute(
          jobId: 'req-2',
          reasonKey: 'disputeReasonDamaged',
          idempotencyKey: key,
        ),
        ErrorCodes.idempotencyKeyReused,
      );
    });
  });

  group('support (M5)', () {
    test('seeded ticket is listed and streamed', () async {
      final repo = MockSupportRepository(db, behavior);
      final tickets = await repo.getTickets();
      expect(tickets.single.id, 'ticket-1');
      expect(tickets.single.messages, hasLength(2));
      expect(tickets.single.messages.last.aiTriage, isTrue);
      expect(
        repo.watchTickets().take(1),
        emits(
          isA<List<SupportTicket>>().having(
            (List<SupportTicket> l) => l.length,
            'length',
            1,
          ),
        ),
      );
    });

    test(
      'create → user message now, AI triage reply after the delay',
      () async {
        final repo = MockSupportRepository(db, behavior);
        final ticket = await repo.createTicket(
          subject: 'App crashes on payment',
          body: 'Every card payment crashes the app.',
          idempotencyKey: newIdempotencyKey(),
        );
        expect(ticket.status, SupportTicketStatus.open);
        expect(ticket.messages, hasLength(1));

        await Future<void>.delayed(const Duration(milliseconds: 200));
        final updated = db.tickets[ticket.id]!;
        expect(updated.messages, hasLength(2));
        expect(updated.messages.last.aiTriage, isTrue);
        expect(updated.messages.last.fromUser, isFalse);
      },
    );

    test('reply appends and triages again; keys are idempotent', () async {
      final repo = MockSupportRepository(db, behavior);
      final key = newIdempotencyKey();
      final updated = await repo.replyToTicket(
        'ticket-1',
        'Any update on this?',
        idempotencyKey: key,
      );
      expect(updated.messages, hasLength(3));
      final replay = await repo.replyToTicket(
        'ticket-1',
        'Any update on this?',
        idempotencyKey: key,
      );
      expect(replay.messages, hasLength(3));
      await expectThrows(
        () => repo.replyToTicket(
          'ticket-1',
          'Different body',
          idempotencyKey: key,
        ),
        ErrorCodes.idempotencyKeyReused,
      );
      await expectThrows(
        () => repo.replyToTicket(
          'ticket-404',
          'Hello',
          idempotencyKey: newIdempotencyKey(),
        ),
        ErrorCodes.unknown,
      );
    });
  });

  group('promos (M5)', () {
    test('redeeming a valid code marks it redeemed once', () async {
      final repo = MockPromoRepository(db, behavior);
      expect((await repo.getPromos()), hasLength(2));
      final promo = await repo.redeemPromo(
        'welcome10',
        idempotencyKey: newIdempotencyKey(),
      );
      expect(promo.code, 'WELCOME10');
      expect(promo.redeemed, isTrue);
      await expectThrows(
        () =>
            repo.redeemPromo('WELCOME10', idempotencyKey: newIdempotencyKey()),
        ErrorCodes.promoInvalid,
      );
    });

    test('unknown and expired codes are refused', () async {
      final repo = MockPromoRepository(db, behavior);
      await expectThrows(
        () => repo.redeemPromo('NOPE', idempotencyKey: newIdempotencyKey()),
        ErrorCodes.promoInvalid,
      );
      await expectThrows(
        () =>
            repo.redeemPromo('FESTIVE20', idempotencyKey: newIdempotencyKey()),
        ErrorCodes.promoInvalid,
      );
    });
  });

  group('settings (M5)', () {
    test('notification preferences default, then persist updates', () async {
      final repo = MockSettingsRepository(db, behavior);
      final defaults = await repo.getNotificationPreferences();
      expect(defaults.push, isTrue);
      expect(defaults.marketing, isFalse);
      expect(defaults.quietStartMinutes, isNull);

      final updated = await repo.updateNotificationPreferences(
        defaults.copyWith(quietStartMinutes: 22 * 60, quietEndMinutes: 6 * 60),
        idempotencyKey: newIdempotencyKey(),
      );
      expect(updated.quietStartMinutes, 22 * 60);
      expect((await repo.getNotificationPreferences()).quietEndMinutes, 6 * 60);
    });

    test('trusted contacts cap at five; removal works', () async {
      final repo = MockSettingsRepository(db, behavior);
      expect((await repo.getTrustedContacts()), hasLength(1)); // seeded tc-1
      for (var i = 0; i < 4; i++) {
        await repo.addTrustedContact(
          name: 'Contact $i',
          phoneE164: '+23470111111$i$i',
          idempotencyKey: newIdempotencyKey(),
        );
      }
      expect((await repo.getTrustedContacts()), hasLength(5));
      await expectThrows(
        () => repo.addTrustedContact(
          name: 'One too many',
          phoneE164: '+2347099999999',
          idempotencyKey: newIdempotencyKey(),
        ),
        ErrorCodes.invalidState,
      );
      await repo.removeTrustedContact(
        'tc-1',
        idempotencyKey: newIdempotencyKey(),
      );
      final remaining = await repo.getTrustedContacts();
      expect(remaining, hasLength(4));
      expect(remaining.any((TrustedContact c) => c.id == 'tc-1'), isFalse);
    });

    test(
      'deletion is scheduled 30 days out; export returns a reference',
      () async {
        final repo = MockSettingsRepository(db, behavior);
        final deletionDate = await repo.requestAccountDeletion(
          idempotencyKey: newIdempotencyKey(),
        );
        final days = deletionDate.difference(DateTime.now()).inDays;
        expect(days, greaterThanOrEqualTo(29));
        final export = await repo.requestDataExport(
          idempotencyKey: newIdempotencyKey(),
        );
        expect(export, startsWith('export-'));
      },
    );
  });
}
