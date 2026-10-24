// Suskii Meet over Supabase. Every read and write is a function
// (list_meetups, get_meetup, my_meetups, create_meetup, join_meetup,
// leave_meetup, cancel_meetup, meetup_attendees); the tables have no client
// grant. Mirrors packages/suskii_data/lib/src/supabase/supabase_meetup_repository.dart.

import { AppError, ErrorCodes } from '@/mocks/errors';
import type {
  GeoPoint,
  Meetup,
  MeetupAttendee,
  MeetupDraft,
  MeetupTopic,
} from '@/mocks/types';

import type { Row, SupabaseGateway } from './gateway';

export function meetupFromRow(row: Row): Meetup {
  const distance = row['distance_km'];
  return {
    id: row['id'] as string,
    title: row['title'] as string,
    description: (row['description'] as string | null) ?? '',
    topic: (row['topic'] as MeetupTopic | null) ?? 'other',
    venueName: row['venue_name'] as string,
    venue: { latitude: Number(row['venue_lat']), longitude: Number(row['venue_lng']) },
    startsAt: row['starts_at'] as string,
    endsAt: row['ends_at'] as string,
    capacity: Number(row['capacity']),
    attendeeCount: Number(row['attendee_count'] ?? 0),
    status: row['status'] === 'cancelled' ? 'cancelled' : 'published',
    hostFirstName: (row['host_first_name'] as string | null) ?? '',
    isHost: row['is_host'] === true,
    isAttending: row['is_attending'] === true,
    distanceKm: distance === null || distance === undefined ? undefined : Number(distance),
  };
}

export class SupabaseMeetupRepository {
  constructor(private readonly gateway: SupabaseGateway) {}

  private async rows(fn: string, args: Record<string, unknown> = {}): Promise<Meetup[]> {
    return ((await this.gateway.rpc(fn, args)) as Row[]).map(meetupFromRow);
  }

  listMeetups(options: { near?: GeoPoint; radiusKm?: number; topic?: MeetupTopic } = {}): Promise<Meetup[]> {
    return this.rows('list_meetups', {
      p_lat: options.near?.latitude,
      p_lng: options.near?.longitude,
      p_radius_km: options.radiusKm ?? 50,
      p_topic: options.topic,
    });
  }

  myMeetups(): Promise<Meetup[]> {
    return this.rows('my_meetups');
  }

  async getMeetup(id: string): Promise<Meetup> {
    const [meetup] = await this.rows('get_meetup', { p_meetup_id: id });
    if (!meetup) throw new AppError(ErrorCodes.meetupNotFound);
    return meetup;
  }

  async createMeetup(draft: MeetupDraft, idempotencyKey: string): Promise<string> {
    return (await this.gateway.rpc('create_meetup', {
      p_idempotency_key: idempotencyKey,
      p_title: draft.title,
      p_description: draft.description,
      p_topic: draft.topic,
      p_venue_name: draft.venueName,
      p_venue_lat: draft.venue.latitude,
      p_venue_lng: draft.venue.longitude,
      p_starts_at: draft.startsAt,
      p_ends_at: draft.endsAt,
      p_capacity: draft.capacity,
    })) as string;
  }

  async joinMeetup(id: string, idempotencyKey: string): Promise<number> {
    return Number(
      await this.gateway.rpc('join_meetup', {
        p_idempotency_key: idempotencyKey,
        p_meetup_id: id,
      }),
    );
  }

  async leaveMeetup(id: string): Promise<boolean> {
    return (await this.gateway.rpc('leave_meetup', { p_meetup_id: id })) === true;
  }

  async cancelMeetup(id: string, idempotencyKey: string): Promise<void> {
    await this.gateway.rpc('cancel_meetup', {
      p_idempotency_key: idempotencyKey,
      p_meetup_id: id,
    });
  }

  async attendees(id: string): Promise<MeetupAttendee[]> {
    return ((await this.gateway.rpc('meetup_attendees', { p_meetup_id: id })) as Row[]).map((r) => ({
      firstName: (r['first_name'] as string | null) ?? '',
      isHost: r['is_host'] === true,
      joinedAt: r['joined_at'] as string,
    }));
  }
}
