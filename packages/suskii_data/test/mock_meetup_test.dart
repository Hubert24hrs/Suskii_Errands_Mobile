import 'package:clock/clock.dart';
import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_data/suskii_data.dart';
import 'package:suskii_domain/suskii_domain.dart';
import 'package:test/test.dart';

Matcher _code(String code) =>
    isA<AppError>().having((AppError e) => e.code, 'code', code);

void main() {
  late MockDatabase db;
  late MockBehavior behavior;
  late MockMeetupRepository repo;

  setUp(() {
    db = MockDatabase();
    behavior = MockBehavior(latency: Duration.zero, currentUserId: 'user-kofi');
    repo = MockMeetupRepository(db, behavior);
  });

  MeetupDraft draft({Duration startIn = const Duration(days: 1)}) {
    final start = clock.now().add(startIn);
    return MeetupDraft(
      title: 'Sunday picnic',
      description: 'Bring something to share.',
      topic: MeetupTopic.foodDrink,
      venueName: 'Muri Okunola Park',
      venue: const GeoPoint(latitude: 6.43, longitude: 3.42),
      startsAt: start,
      endsAt: start.add(const Duration(hours: 3)),
      capacity: 2,
    );
  }

  test(
    'lists upcoming meet-ups soonest first, with distance near a point',
    () async {
      final list = await repo.listMeetups(
        near: const GeoPoint(latitude: 6.45, longitude: 3.40),
      );
      expect(list, isNotEmpty);
      expect(list.first.startsAt.isBefore(list.last.startsAt), isTrue);
      expect(list.every((Meetup m) => m.distanceKm != null), isTrue);
      expect(list.first.hostFirstName, isNot(contains(' ')));
    },
  );

  test('a host creates one; others join until it is full', () async {
    final d = draft();
    final id = await repo.createMeetup(d, idempotencyKey: 'k-create');
    expect(await repo.createMeetup(d, idempotencyKey: 'k-create'), id);
    expect((await repo.getMeetup(id)).isHost, isTrue);

    behavior.currentUserId = 'user-ada';
    expect(await repo.joinMeetup(id, idempotencyKey: 'k-j1'), 1);
    behavior.currentUserId = 'user-chidi';
    expect(await repo.joinMeetup(id, idempotencyKey: 'k-j2'), 2);
    expect(
      (await repo.attendees(id)).map((MeetupAttendee a) => a.firstName),
      <String>['Kofi', 'Adaeze', 'Chidi'],
    );
    behavior.currentUserId = 'user-bola';
    await expectLater(
      repo.joinMeetup(id, idempotencyKey: 'k-j3'),
      throwsA(_code(ErrorCodes.meetupFull)),
    );
    await expectLater(
      repo.attendees(id),
      throwsA(_code(ErrorCodes.meetupNotFound)),
    );
  });

  test('time rules and the host limit', () async {
    await expectLater(
      repo.createMeetup(
        draft(startIn: const Duration(minutes: 5)),
        idempotencyKey: 'k-soon',
      ),
      throwsA(_code(ErrorCodes.meetupTimeInvalid)),
    );
    for (var i = 0; i < 3; i++) {
      await repo.createMeetup(
        draft(startIn: Duration(days: i + 1)),
        idempotencyKey: 'k-$i',
      );
    }
    await expectLater(
      repo.createMeetup(
        draft(startIn: const Duration(days: 9)),
        idempotencyKey: 'k-4',
      ),
      throwsA(_code(ErrorCodes.meetupLimitReached)),
    );
  });

  test('cancelling takes it off the list; only the host can', () async {
    final id = await repo.createMeetup(draft(), idempotencyKey: 'k-c');
    behavior.currentUserId = 'user-ada';
    await expectLater(
      repo.cancelMeetup(id, idempotencyKey: 'k-x'),
      throwsA(_code(ErrorCodes.meetupNotFound)),
    );
    behavior.currentUserId = 'user-kofi';
    await repo.cancelMeetup(id, idempotencyKey: 'k-x2');
    expect((await repo.listMeetups()).any((Meetup m) => m.id == id), isFalse);
    expect((await repo.myMeetups()).single.isCancelled, isTrue);
  });
}
