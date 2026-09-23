import 'dart:async';

import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_data/suskii_data.dart';
import 'package:suskii_domain/suskii_domain.dart';
import 'package:test/test.dart';

/// M8.6 provider execution: provider "my jobs" feeds, proof-of-execution
/// submission and the completion gate (category proof requirements +
/// delivery PIN), plus the submitOffer server-clock/TTL fix.
void main() {
  late MockDatabase db;
  late MockBehavior behavior;

  setUp(() {
    db = MockDatabase();
    // Signed-in persona user-ada is a verified provider (NG).
    behavior = MockBehavior(latency: Duration.zero);
  });

  Matcher expectCode(String code) =>
      isA<AppError>().having((AppError e) => e.code, 'code', code);

  Future<void> expectThrows(Future<Object?> Function() fn, String code) =>
      expectLater(fn, throwsA(expectCode(code)));

  group('submitOffer TTL fix', () {
    test('offer expiry uses the server clock and the category TTL', () async {
      behavior.offerTtlOverride = const Duration(minutes: 3);
      final repo = MockProviderRepository(db, behavior);
      final deviceNow = DateTime.now().toUtc();
      final offer = await repo.submitOffer(
        requestId: 'req-feed-1',
        amount: const Money(350000, 'NGN'),
        idempotencyKey: newIdempotencyKey(),
      );
      // TTL comes from the override (category TTL when unset) — not the
      // previously hardcoded 10 minutes.
      expect(
        offer.expiresAt!.difference(offer.createdAt),
        const Duration(minutes: 3),
      );
      // createdAt is on the skewed server clock (7s), not raw device time.
      final skew = offer.createdAt.difference(deviceNow);
      expect(skew.inSeconds, greaterThanOrEqualTo(3));
      expect(skew.inSeconds, lessThan(60));
    });

    test('without an override the category offerTtlSeconds applies', () async {
      final repo = MockProviderRepository(db, behavior);
      final offer = await repo.submitOffer(
        requestId: 'req-feed-1',
        amount: const Money(350000, 'NGN'),
        idempotencyKey: newIdempotencyKey(),
      );
      expect(
        offer.expiresAt!.difference(offer.createdAt),
        Duration(
          seconds: db.categories
              .firstWhere((c) => c.id == 'errands_delivery')
              .offerTtlSeconds,
        ),
      );
    });
  });

  group('watchMyJobs / getMyJobsHistory', () {
    test('streams the provider’s active jobs, newest first', () async {
      final repo = MockProviderRepository(db, behavior);
      final jobs = await repo.watchMyJobs().first;
      expect(jobs.map((JobRequest j) => j.id).toList(), <String>[
        'req-p1',
        'req-p2',
        'req-p3',
        'req-p4',
      ]);
    });

    test('excludes terminal jobs and other providers’ jobs', () async {
      final repo = MockProviderRepository(db, behavior);
      final jobs = await repo.watchMyJobs().first;
      final ids = jobs.map((JobRequest j) => j.id).toList();
      expect(ids, isNot(contains('req-p5'))); // closed → history
      expect(ids, isNot(contains('req-2'))); // provider-musa's job
      expect(jobs.every((JobRequest j) => !j.status.isTerminal), isTrue);
      expect(jobs.every((JobRequest j) => j.providerId == 'user-ada'), isTrue);
    });

    test('re-emits when an assigned job changes', () async {
      final repo = MockProviderRepository(db, behavior);
      final iterator = StreamIterator<List<JobRequest>>(repo.watchMyJobs());
      await iterator.moveNext();
      final updated = db.requests['req-p1']!.copyWith(
        status: JobStatus.assigned,
      );
      db.requests['req-p1'] = updated;
      db.jobEvents.add(updated);
      await iterator.moveNext();
      expect(
        iterator.current.firstWhere((JobRequest j) => j.id == 'req-p1').status,
        JobStatus.assigned,
      );
      await iterator.cancel();
    });

    test('history is terminal-only and cursor-paginated', () async {
      final repo = MockProviderRepository(db, behavior);
      final history = await repo.getMyJobsHistory();
      expect(history.map((JobRequest j) => j.id), <String>['req-p5']);
      expect(history.every((JobRequest j) => j.status.isTerminal), isTrue);
      // Cursor = last id of the previous page → no more pages here.
      final page2 = await repo.getMyJobsHistory(cursor: 'req-p5');
      expect(page2, isEmpty);
    });
  });

  group('proofs (M8.6)', () {
    test('submitProof is provider-only', () async {
      behavior.currentUserId = 'user-emeka'; // the customer of req-p2
      final repo = MockJobProgressRepository(db, behavior);
      await expectThrows(
        () => repo.submitProof(
          jobId: 'req-p2',
          kind: ProofKind.photo,
          storagePath: 'req-p2/pickup.jpg',
          idempotencyKey: newIdempotencyKey(),
        ),
        ErrorCodes.permissionDenied,
      );
    });

    test('submitProof is refused outside the execution window', () async {
      final repo = MockJobProgressRepository(db, behavior);
      await expectThrows(
        () => repo.submitProof(
          jobId: 'req-p1', // paidHeld — not yet in progress
          kind: ProofKind.photo,
          storagePath: 'req-p1/items.jpg',
          idempotencyKey: newIdempotencyKey(),
        ),
        ErrorCodes.invalidState,
      );
    });

    test('storage paths outside the job prefix are refused', () async {
      final repo = MockJobProgressRepository(db, behavior);
      await expectThrows(
        () => repo.submitProof(
          jobId: 'req-p2',
          kind: ProofKind.photo,
          storagePath: 'req-p1/evil.jpg', // not under req-p2/
          idempotencyKey: newIdempotencyKey(),
        ),
        ErrorCodes.permissionDenied,
      );
    });

    test(
      'proof replay is idempotent; key reuse with new args is refused',
      () async {
        final repo = MockJobProgressRepository(db, behavior);
        final key = newIdempotencyKey();
        final proof = await repo.submitProof(
          jobId: 'req-p2',
          kind: ProofKind.photo,
          storagePath: 'req-p2/pickup.jpg',
          idempotencyKey: key,
        );
        final replay = await repo.submitProof(
          jobId: 'req-p2',
          kind: ProofKind.photo,
          storagePath: 'req-p2/pickup.jpg',
          idempotencyKey: key,
        );
        expect(replay.id, proof.id);
        expect(db.proofs['req-p2']!.length, 1);
        await expectThrows(
          () => repo.submitProof(
            jobId: 'req-p2',
            kind: ProofKind.photo,
            storagePath: 'req-p2/other.jpg',
            idempotencyKey: key,
          ),
          ErrorCodes.idempotencyKeyReused,
        );
      },
    );

    test('getProofs returns the job’s proofs to participants only', () async {
      final repo = MockJobProgressRepository(db, behavior);
      final proofs = await repo.getProofs('req-p3');
      expect(proofs.single.id, 'proof-p3-1');
      expect(proofs.single.kind, ProofKind.signature);
      behavior.currentUserId = 'user-kofi'; // not a participant
      await expectThrows(
        () => repo.getProofs('req-p3'),
        ErrorCodes.permissionDenied,
      );
    });
  });

  group('completion gate (ERR_PROOF_REQUIRED)', () {
    test('photo requirement + delivery PIN gate completion', () async {
      final repo = MockJobProgressRepository(db, behavior);
      // req-p2: errands_delivery (photo ×1), in progress, has a destination.
      await expectThrows(
        () => repo.requestStatusChange(
          'req-p2',
          JobStatus.completedByProvider,
          idempotencyKey: newIdempotencyKey(),
        ),
        ErrorCodes.proofRequired,
      );
      await repo.submitProof(
        jobId: 'req-p2',
        kind: ProofKind.photo,
        storagePath: 'req-p2/delivered.jpg',
        idempotencyKey: newIdempotencyKey(),
      );
      // Proof met, but the delivery PIN is not verified yet.
      await expectThrows(
        () => repo.requestStatusChange(
          'req-p2',
          JobStatus.completedByProvider,
          idempotencyKey: newIdempotencyKey(),
        ),
        ErrorCodes.proofRequired,
      );
      await repo.verifyHandoverPin(
        'req-p2',
        '4281',
        kind: HandoverPinKind.delivery,
        idempotencyKey: newIdempotencyKey(),
      );
      final done = await repo.requestStatusChange(
        'req-p2',
        JobStatus.completedByProvider,
        idempotencyKey: newIdempotencyKey(),
      );
      expect(done.status, JobStatus.completedByProvider);
    });

    test('multi-kind requirements each need their count (shopping)', () async {
      final repo = MockJobProgressRepository(db, behavior);
      // Move req-p1 (shopping: photo ×1 + receipt ×1, destination) into
      // progress — the state the provider UI reaches after arrival.
      db.requests['req-p1'] = db.requests['req-p1']!.copyWith(
        status: JobStatus.inProgress,
      );
      await expectThrows(
        () => repo.requestStatusChange(
          'req-p1',
          JobStatus.completedByProvider,
          idempotencyKey: newIdempotencyKey(),
        ),
        ErrorCodes.proofRequired,
      );
      await repo.submitProof(
        jobId: 'req-p1',
        kind: ProofKind.photo,
        storagePath: 'req-p1/items.jpg',
        idempotencyKey: newIdempotencyKey(),
      );
      // Receipt still missing.
      await expectThrows(
        () => repo.requestStatusChange(
          'req-p1',
          JobStatus.completedByProvider,
          idempotencyKey: newIdempotencyKey(),
        ),
        ErrorCodes.proofRequired,
      );
      await repo.submitProof(
        jobId: 'req-p1',
        kind: ProofKind.receipt,
        storagePath: 'req-p1/receipt.jpg',
        idempotencyKey: newIdempotencyKey(),
      );
      await repo.verifyHandoverPin(
        'req-p1',
        '4281',
        kind: HandoverPinKind.delivery,
        idempotencyKey: newIdempotencyKey(),
      );
      final done = await repo.requestStatusChange(
        'req-p1',
        JobStatus.completedByProvider,
        idempotencyKey: newIdempotencyKey(),
      );
      expect(done.status, JobStatus.completedByProvider);
    });

    test(
      'jobs without requirements or a destination complete directly',
      () async {
        final repo = MockJobProgressRepository(db, behavior);
        // personal_assistance has no proof requirements and req-feed-5 has no
        // destination; assign it to the persona mid-execution.
        db.requests['req-feed-5'] = db.requests['req-feed-5']!.copyWith(
          status: JobStatus.inProgress,
          providerId: 'user-ada',
        );
        final done = await repo.requestStatusChange(
          'req-feed-5',
          JobStatus.completedByProvider,
          idempotencyKey: newIdempotencyKey(),
        );
        expect(done.status, JobStatus.completedByProvider);
      },
    );
  });

  group('pickup PIN starts the work', () {
    test('revealHandoverPin hands out the PIN on demand', () async {
      final repo = MockJobProgressRepository(db, behavior);
      expect(
        await repo.revealHandoverPin('req-p1', kind: HandoverPinKind.pickup),
        '4281',
      );
      expect(
        await repo.revealHandoverPin('req-p1', kind: HandoverPinKind.delivery),
        '4281',
      );
    });

    test('a verified pickup PIN moves arrived → inProgress', () async {
      final repo = MockJobProgressRepository(db, behavior);
      db.requests['req-p1'] = db.requests['req-p1']!.copyWith(
        status: JobStatus.arrived,
      );
      final result = await repo.verifyHandoverPin(
        'req-p1',
        '4281',
        kind: HandoverPinKind.pickup,
        idempotencyKey: newIdempotencyKey(),
      );
      expect(result.verified, isTrue);
      expect(result.status, JobStatus.inProgress);
      expect(db.requests['req-p1']!.status, JobStatus.inProgress);
    });

    test('inProgress is not a settable target', () async {
      final repo = MockJobProgressRepository(db, behavior);
      db.requests['req-p1'] = db.requests['req-p1']!.copyWith(
        status: JobStatus.arrived,
      );
      await expectThrows(
        () => repo.requestStatusChange(
          'req-p1',
          JobStatus.inProgress,
          idempotencyKey: newIdempotencyKey(),
        ),
        ErrorCodes.permissionDenied,
      );
    });

    test('pickup and delivery PINs have separate attempt counters', () async {
      final repo = MockJobProgressRepository(db, behavior);
      // Spend four pickup attempts; the delivery counter is untouched.
      for (var i = 0; i < 4; i++) {
        final result = await repo.verifyHandoverPin(
          'req-p2',
          '0000',
          kind: HandoverPinKind.pickup,
          idempotencyKey: newIdempotencyKey(),
        );
        expect(result.verified, isFalse);
      }
      final delivery = await repo.verifyHandoverPin(
        'req-p2',
        '0000',
        kind: HandoverPinKind.delivery,
        idempotencyKey: newIdempotencyKey(),
      );
      expect(delivery.attemptsRemaining, 4);
    });
  });
}
