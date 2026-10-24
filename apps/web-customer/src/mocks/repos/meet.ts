// Suskii Meet on the mock backend. Mirrors MockMeetupRepository in
// packages/suskii_data/lib/src/mock/mock_repositories.dart and the rules of
// supabase/migrations/20261024120100_suskii_meet.sql.

import { AppError, ErrorCodes } from '../errors';
import type { GeoPoint, Meetup, MeetupAttendee, MeetupDraft, MeetupTopic } from '../types';
import { MockRepo } from './base';

interface StoredMeetup {
  meetup: Meetup;
  hostId: string;
  /** People from outside the demo already going. */
  baseCount: number;
  going: Map<string, string>;
}

const HOUR = 3_600_000;

function km(a: GeoPoint, b: GeoPoint): number {
  const x =
    ((b.longitude - a.longitude) * Math.PI) / 180 * Math.cos((((a.latitude + b.latitude) / 2) * Math.PI) / 180);
  const y = ((b.latitude - a.latitude) * Math.PI) / 180;
  return Math.round(Math.sqrt(x * x + y * y) * 6371 * 10) / 10;
}

export class MockMeetupRepository extends MockRepo {
  private readonly store = new Map<string, StoredMeetup>();
  private seeded = false;

  private seed(): void {
    if (this.seeded) return;
    this.seeded = true;
    const day = new Date(this.now());
    day.setHours(10, 0, 0, 0);
    const start = day.getTime() + 2 * 24 * HOUR;
    const add = (
      id: string,
      hostId: string,
      title: string,
      description: string,
      topic: MeetupTopic,
      venueName: string,
      venue: GeoPoint,
      startsAt: number,
      hours: number,
      capacity: number,
      baseCount: number,
    ) =>
      this.store.set(id, {
        hostId,
        baseCount,
        going: new Map(),
        meetup: {
          id,
          title,
          description,
          topic,
          venueName,
          venue,
          startsAt: new Date(startsAt).toISOString(),
          endsAt: new Date(startsAt + hours * HOUR).toISOString(),
          capacity,
          attendeeCount: 0,
          status: 'published',
          hostFirstName: '',
          isHost: false,
          isAttending: false,
        },
      });
    add('meet-1', 'user-chidi', 'Saturday book club',
      'We read one novel a month and talk about it over tea.', 'learning',
      'Terra Kulture, Victoria Island', { latitude: 6.43, longitude: 3.42 }, start, 2, 20, 6);
    add('meet-2', 'user-ada', 'Morning run, Ikoyi bridge',
      'An easy 5 km at conversation pace. All levels welcome.', 'sports_fitness',
      'Falomo roundabout, Ikoyi', { latitude: 6.4446, longitude: 3.4256 }, start + 20 * HOUR, 1, 15, 15);
    add('meet-3', 'user-chidi', 'Tech founders networking',
      'Short intros, then open conversation. Bring a card.', 'business_networking',
      'Co-Creation Hub, Yaba', { latitude: 6.5095, longitude: 3.3711 }, start + 103 * HOUR, 3, 40, 12);
  }

  private view(s: StoredMeetup, near?: GeoPoint): Meetup {
    const uid = this.currentUser.id;
    const host = this.db.users[s.hostId];
    return {
      ...s.meetup,
      attendeeCount: s.baseCount + s.going.size,
      hostFirstName: (host?.displayName ?? '').split(' ')[0] ?? '',
      isHost: s.hostId === uid,
      isAttending: s.going.has(uid),
      distanceKm: near ? km(near, s.meetup.venue) : undefined,
    };
  }

  private find(id: string): StoredMeetup {
    this.seed();
    const s = this.store.get(id);
    if (!s) throw new AppError(ErrorCodes.meetupNotFound);
    return s;
  }

  async listMeetups(options: { near?: GeoPoint; radiusKm?: number; topic?: MeetupTopic } = {}): Promise<Meetup[]> {
    await this.gate();
    this.seed();
    const now = this.now().getTime();
    const radius = options.radiusKm ?? 50;
    return [...this.store.values()]
      .filter(
        (s) =>
          s.meetup.status === 'published' &&
          Date.parse(s.meetup.endsAt) > now &&
          (!options.topic || s.meetup.topic === options.topic),
      )
      .map((s) => this.view(s, options.near))
      .filter((m) => m.distanceKm === undefined || m.distanceKm <= radius)
      .sort((a, b) => Date.parse(a.startsAt) - Date.parse(b.startsAt));
  }

  async myMeetups(): Promise<Meetup[]> {
    await this.gate();
    this.seed();
    return [...this.store.values()]
      .map((s) => this.view(s))
      .filter((m) => m.isHost || m.isAttending)
      .sort((a, b) => Date.parse(b.startsAt) - Date.parse(a.startsAt));
  }

  async getMeetup(id: string): Promise<Meetup> {
    await this.gate();
    return this.view(this.find(id));
  }

  async createMeetup(draft: MeetupDraft, idempotencyKey: string): Promise<string> {
    await this.gate();
    this.seed();
    return this.idempotent('createMeetup', idempotencyKey, `${draft.title}|${draft.startsAt}`, () => {
      const now = this.now().getTime();
      const title = draft.title.trim();
      const venueName = draft.venueName.trim();
      if (
        title.length < 3 || title.length > 80 || venueName.length < 2 || venueName.length > 120 ||
        draft.description.length > 1000 || draft.capacity < 2 || draft.capacity > 500
      ) {
        throw new AppError(ErrorCodes.invalidState);
      }
      const start = Date.parse(draft.startsAt);
      const end = Date.parse(draft.endsAt);
      if (start < now + 30 * 60_000 || start > now + 90 * 24 * HOUR || end <= start || end > start + 24 * HOUR) {
        throw new AppError(ErrorCodes.meetupTimeInvalid);
      }
      const uid = this.currentUser.id;
      const hosted = [...this.store.values()].filter(
        (s) => s.hostId === uid && s.meetup.status === 'published' && Date.parse(s.meetup.endsAt) > now,
      );
      if (hosted.length >= 3) throw new AppError(ErrorCodes.meetupLimitReached);
      const id = `meet-${now}-${this.store.size + 1}`;
      this.store.set(id, {
        hostId: uid,
        baseCount: 0,
        going: new Map(),
        meetup: {
          id,
          title,
          description: draft.description.trim(),
          topic: draft.topic,
          venueName,
          venue: draft.venue,
          startsAt: new Date(start).toISOString(),
          endsAt: new Date(end).toISOString(),
          capacity: draft.capacity,
          attendeeCount: 0,
          status: 'published',
          hostFirstName: '',
          isHost: true,
          isAttending: false,
        },
      });
      return id;
    });
  }

  async joinMeetup(id: string, idempotencyKey: string): Promise<number> {
    await this.gate();
    return this.idempotent('joinMeetup', idempotencyKey, id, () => {
      const s = this.find(id);
      const m = this.view(s);
      if (m.isHost) throw new AppError(ErrorCodes.invalidState);
      if (m.isAttending) return m.attendeeCount;
      if (m.status !== 'published' || Date.parse(m.startsAt) <= this.now().getTime()) {
        throw new AppError(ErrorCodes.meetupClosed);
      }
      if (m.attendeeCount >= m.capacity) throw new AppError(ErrorCodes.meetupFull);
      s.going.set(this.currentUser.id, this.now().toISOString());
      return m.attendeeCount + 1;
    });
  }

  async leaveMeetup(id: string): Promise<boolean> {
    await this.gate();
    return this.find(id).going.delete(this.currentUser.id);
  }

  async cancelMeetup(id: string, idempotencyKey: string): Promise<void> {
    await this.gate();
    await this.idempotent('cancelMeetup', idempotencyKey, id, () => {
      const s = this.find(id);
      if (s.hostId !== this.currentUser.id) throw new AppError(ErrorCodes.meetupNotFound);
      s.meetup = { ...s.meetup, status: 'cancelled' };
      return true;
    });
  }

  async attendees(id: string): Promise<MeetupAttendee[]> {
    await this.gate();
    const s = this.find(id);
    const m = this.view(s);
    if (!m.isHost && !m.isAttending) throw new AppError(ErrorCodes.meetupNotFound);
    return [
      { firstName: m.hostFirstName, isHost: true, joinedAt: m.startsAt },
      ...[...s.going.entries()].map(([userId, joinedAt]) => ({
        firstName: (this.db.users[userId]?.displayName ?? '').split(' ')[0] ?? '',
        isHost: false,
        joinedAt,
      })),
    ];
  }
}
