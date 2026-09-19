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

  /// Awaits a closure expected to throw so later statements cannot race the
  /// gated mock call.
  Future<void> expectThrows(Future<Object?> Function() fn, String code) =>
      expectLater(fn, throwsA(expectCode(code)));

  group('provider tools (M6)', () {
    test('availability round-trips per provider', () async {
      final repo = MockProviderToolsRepository(db, behavior);
      final seeded = await repo.getAvailability();
      expect(seeded, hasLength(6)); // Mon–Sat for user-ada
      final updated = await repo.setAvailability(
        const <AvailabilitySlot>[
          AvailabilitySlot(dayOfWeek: 2, startMinutes: 540, endMinutes: 720),
        ],
        idempotencyKey: newIdempotencyKey(),
      );
      expect(updated, hasLength(1));
      expect((await repo.getAvailability()).single.dayOfWeek, 2);
    });

    test('invalid windows are refused', () async {
      final repo = MockProviderToolsRepository(db, behavior);
      await expectThrows(
        () => repo.setAvailability(
          const <AvailabilitySlot>[
            AvailabilitySlot(dayOfWeek: 9, startMinutes: 0, endMinutes: 60),
          ],
          idempotencyKey: newIdempotencyKey(),
        ),
        ErrorCodes.invalidState,
      );
      await expectThrows(
        () => repo.setAvailability(
          const <AvailabilitySlot>[
            AvailabilitySlot(dayOfWeek: 1, startMinutes: 600, endMinutes: 600),
          ],
          idempotencyKey: newIdempotencyKey(),
        ),
        ErrorCodes.invalidState,
      );
    });

    test('earnings goal keeps server-computed progress on update', () async {
      final repo = MockProviderToolsRepository(db, behavior);
      final seeded = await repo.getEarningsGoal();
      expect(seeded!.target, const Money(15000000, 'NGN'));
      final updated = await repo.setEarningsGoal(
        const Money(20000000, 'NGN'),
        GoalPeriod.monthly,
        idempotencyKey: newIdempotencyKey(),
      );
      expect(updated.period, GoalPeriod.monthly);
      // Progress is NOT reset by a client-side target change.
      expect(updated.progress, const Money(9050000, 'NGN'));
    });

    test('heatmap is sorted by intensity, descending', () async {
      final repo = MockProviderToolsRepository(db, behavior);
      final zones = await repo.getDemandHeatmap();
      expect(zones, isNotEmpty);
      for (var i = 0; i < zones.length - 1; i++) {
        expect(zones[i].intensity >= zones[i + 1].intensity, isTrue);
      }
    });

    test('instant payout quote: fee + net == amount; payout debits wallet',
        () async {
      final repo = MockProviderToolsRepository(db, behavior);
      const amount = Money(1000000, 'NGN'); // ₦10,000
      final quote = await repo.quoteInstantPayout(amount);
      expect(quote.fee.minorUnits + quote.net.minorUnits, amount.minorUnits);
      expect(quote.fee.minorUnits, greaterThan(0));

      final before = db.wallets['user-ada']!.available.minorUnits;
      final txn = await repo.requestInstantPayout(
        amount,
        idempotencyKey: newIdempotencyKey(),
      );
      expect(txn.amount, quote.net);
      expect(txn.status, WalletTransactionStatus.completed);
      expect(
        db.wallets['user-ada']!.available.minorUnits,
        before - amount.minorUnits,
      );
    });

    test('instant payout enforces balance and KYC', () async {
      final repo = MockProviderToolsRepository(db, behavior);
      await expectThrows(
        () => repo.requestInstantPayout(
          const Money(99999999, 'NGN'), // more than available
          idempotencyKey: newIdempotencyKey(),
        ),
        ErrorCodes.insufficientBalance,
      );
      behavior.currentUserId = 'user-emeka'; // provider KYC rejected
      await expectThrows(
        () => repo.requestInstantPayout(
          const Money(100000, 'NGN'),
          idempotencyKey: newIdempotencyKey(),
        ),
        ErrorCodes.kycIncomplete,
      );
    });
  });

  group('business console (M6)', () {
    test('individual providers get no organization; members see the org',
        () async {
      final repo = MockOrganizationRepository(db, behavior);
      expect(await repo.getMyOrganization(), isNull); // user-ada: individual
      await expectThrows(
        () => repo.getMembers(),
        ErrorCodes.permissionDenied,
      );
      behavior.currentUserId = 'user-bola';
      final org = await repo.getMyOrganization();
      expect(org!.name, 'SwiftErrands Ltd');
      expect((await repo.getMembers()), hasLength(4));
    });

    test('per-worker earnings are redacted for non-owners', () async {
      behavior.currentUserId = 'user-tayo'; // worker
      final repo = MockOrganizationRepository(db, behavior);
      final members = await repo.getMembers();
      expect(
        members.every((OrgMember m) => m.earningsToDate == null),
        isTrue,
      );
      behavior.currentUserId = 'user-bola'; // owner
      final ownerView = await repo.getMembers();
      expect(
        ownerView.any((OrgMember m) => (m.earningsToDate?.minorUnits ?? 0) > 0),
        isTrue,
      );
    });

    test('invite is manager-only, idempotent, and blocks a second owner',
        () async {
      behavior.currentUserId = 'user-bola';
      final repo = MockOrganizationRepository(db, behavior);
      final key = newIdempotencyKey();
      final invited = await repo.inviteMember(
        phoneE164: '+2348011122233',
        role: BusinessRole.worker,
        idempotencyKey: key,
      );
      expect(invited.verificationStatus, VerificationStatus.pending);
      expect((await repo.getMembers()), hasLength(5));
      final replay = await repo.inviteMember(
        phoneE164: '+2348011122233',
        role: BusinessRole.worker,
        idempotencyKey: key,
      );
      expect(replay.userId, invited.userId);
      expect((await repo.getMembers()), hasLength(5));
      await expectThrows(
        () => repo.inviteMember(
          phoneE164: '+2348099900011',
          role: BusinessRole.owner,
          idempotencyKey: newIdempotencyKey(),
        ),
        ErrorCodes.invalidState,
      );
      // A worker cannot invite.
      behavior.currentUserId = 'user-tayo';
      await expectThrows(
        () => repo.inviteMember(
          phoneE164: '+2348099900022',
          role: BusinessRole.worker,
          idempotencyKey: newIdempotencyKey(),
        ),
        ErrorCodes.permissionDenied,
      );
    });

    test('removeMember drops the member but never the owner', () async {
      behavior.currentUserId = 'user-bola';
      final repo = MockOrganizationRepository(db, behavior);
      await repo.removeMember(
        'user-seun',
        idempotencyKey: newIdempotencyKey(),
      );
      final members = await repo.getMembers();
      expect(members, hasLength(3));
      expect(members.any((OrgMember m) => m.userId == 'user-seun'), isFalse);
      await expectThrows(
        () => repo.removeMember('user-bola',
            idempotencyKey: newIdempotencyKey()),
        ErrorCodes.invalidState,
      );
    });

    test('dispatch assigns an org job to a verified worker', () async {
      behavior.currentUserId = 'user-bola';
      final repo = MockOrganizationRepository(db, behavior);
      final assignable = await repo.getAssignableJobs();
      expect(assignable.map((JobRequest r) => r.id), contains('req-org-1'));
      final updated = await repo.assignJob(
        jobId: 'req-org-1',
        workerId: 'user-tayo',
        idempotencyKey: newIdempotencyKey(),
      );
      expect(updated.status, JobStatus.assigned);
      expect(db.orgAssignments['req-org-1'], 'user-tayo');
      // No longer assignable.
      expect(
        (await repo.getAssignableJobs()).any((JobRequest r) => r.id == 'req-org-1'),
        isFalse,
      );
      // Re-dispatch is refused.
      await expectThrows(
        () => repo.assignJob(
          jobId: 'req-org-1',
          workerId: 'user-tayo',
          idempotencyKey: newIdempotencyKey(),
        ),
        ErrorCodes.invalidState,
      );
      // Unverified workers cannot take jobs (worker rule precedes the
      // assignability check).
      await expectThrows(
        () => repo.assignJob(
          jobId: 'req-org-1',
          workerId: 'user-seun', // in review
          idempotencyKey: newIdempotencyKey(),
        ),
        ErrorCodes.permissionDenied,
      );
    });

    test('vehicles: upsert, assign to worker, reject non-worker assignee',
        () async {
      behavior.currentUserId = 'user-bola';
      final repo = MockOrganizationRepository(db, behavior);
      expect((await repo.getVehicles()), hasLength(3));
      final updated = await repo.assignVehicle(
        'veh-2',
        'user-tayo',
        idempotencyKey: newIdempotencyKey(),
      );
      expect(updated.assignedWorkerId, 'user-tayo');
      await expectThrows(
        () => repo.assignVehicle(
          'veh-2',
          'user-dafe', // dispatcher, not a worker
          idempotencyKey: newIdempotencyKey(),
        ),
        ErrorCodes.permissionDenied,
      );
      final added = await repo.upsertVehicle(
        const Vehicle(
          id: 'veh-4',
          organizationId: '', // server overwrites with the caller's org
          type: VehicleType.tricycle,
          plate: 'LAG-777-ZZ',
        ),
        idempotencyKey: newIdempotencyKey(),
      );
      expect(added.organizationId, 'org-swift');
      expect((await repo.getVehicles()), hasLength(4));
    });
  });
}
