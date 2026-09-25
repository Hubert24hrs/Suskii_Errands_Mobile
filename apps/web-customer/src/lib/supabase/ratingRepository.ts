// RatingRepository over Supabase: `rate_job` writes the rating server-side
// (window and one-per-party rules enforced there); reads are RLS-scoped
// selects on `ratings` filtered to the caller as rater. Mirrors
// packages/suskii_data/lib/src/supabase/supabase_rating_repository.dart.

import { AppError, ErrorCodes } from '@/mocks/errors';
import type { Rating } from '@/mocks/types';

import { SupabaseGateway } from './gateway';
import { ratingFromRow } from './mappers';

const ratingColumns =
  'id, request_id, rater_id, ratee_id, direction, stars, tags, comment, ' +
  'created_at';

export class SupabaseRatingRepository {
  constructor(private readonly gateway: SupabaseGateway) {}

  /** Ratings are blind: this only ever returns the current user's own
   * rating for the job. */
  async getMyRatingForJob(jobId: string): Promise<Rating | undefined> {
    const rows = await this.gateway.selectList('ratings', ratingColumns, {
      column: 'request_id',
      value: jobId,
    });
    const myId = await this.gateway.currentAuthUserId();
    for (const row of rows) {
      if (row['rater_id'] === myId) return ratingFromRow(row);
    }
    return undefined;
  }

  /** One rating per party per job; stars 1–5; rateable states only (all
   * enforced server-side). */
  async submitRating(options: {
    jobId: string;
    stars: number;
    idempotencyKey: string;
    tagKeys?: string[];
    comment?: string;
  }): Promise<Rating> {
    const id = await this.gateway.rpc('rate_job', {
      p_idempotency_key: options.idempotencyKey,
      p_request_id: options.jobId,
      p_stars: options.stars,
      p_tags:
        options.tagKeys === undefined || options.tagKeys.length === 0
          ? undefined
          : options.tagKeys,
      p_comment: options.comment,
    });
    const row = await this.gateway.selectSingle(
      'ratings',
      ratingColumns,
      'id',
      SupabaseGateway.asId(id),
    );
    if (row === null) throw new AppError(ErrorCodes.unknown);
    return ratingFromRow(row);
  }
}
