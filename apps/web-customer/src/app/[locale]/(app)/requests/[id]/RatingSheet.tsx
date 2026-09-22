'use client';

import { useRef, useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import type { Dictionary } from '@/lib/i18n/en';
import { newIdempotencyKey } from '@/lib/idempotency';
import { ratingRepository } from '@/mocks/repositories';
import type { Rating } from '@/mocks/types';
import { StateBlock } from '@/components/StateBlock';
import { errorText } from '../_shared';

// Server-side tag keys; labels resolve through dict.requests.rating.tags.
const RATING_TAG_KEYS = [
  'ratingTagPunctual',
  'ratingTagCareful',
  'ratingTagCommunicative',
  'ratingTagProfessional',
  'ratingTagSlow',
  'ratingTagRude',
] as const;

function Stars({ value, className }: { value: number; className?: string }) {
  return (
    <span className={className} aria-label={`${value}/5`}>
      {'★'.repeat(value)}
      {'☆'.repeat(5 - value)}
    </span>
  );
}

function tagLabel(dict: Dictionary, key: string): string {
  const table = dict.requests.rating.tags as Record<string, string>;
  return table[key] ?? key;
}

function RatingSummary({ rating, dict }: { rating: Rating; dict: Dictionary }) {
  return (
    <div className="rounded-lg border border-outline bg-surface-raised p-xl dark:border-outline-dark dark:bg-surface-dark-raised">
      <Stars value={rating.stars} className="text-title-large text-warning dark:text-warning-dark" />
      {rating.tagKeys.length > 0 ? (
        <ul className="mt-sm flex flex-wrap gap-sm">
          {rating.tagKeys.map((key) => (
            <li
              key={key}
              className="rounded-pill border border-outline px-md py-xs text-body-small text-ink-secondary dark:border-outline-dark dark:text-ink-dark-secondary"
            >
              {tagLabel(dict, key)}
            </li>
          ))}
        </ul>
      ) : null}
      {rating.comment ? (
        <p className="mt-sm text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
          {rating.comment}
        </p>
      ) : null}
    </div>
  );
}

export function RatingSheet({ jobId, dict }: { jobId: string; dict: Dictionary }) {
  const queryClient = useQueryClient();
  const myRatingQuery = useQuery({
    queryKey: ['rating', jobId],
    queryFn: () => ratingRepository.getMyRatingForJob(jobId),
  });

  const [stars, setStars] = useState(0);
  const [tags, setTags] = useState<Set<string>>(new Set());
  const [comment, setComment] = useState('');
  // One key for the whole rating intent; reused on retry, reset on success
  // or when the inputs change.
  const intent = useRef<{ key: string; fingerprint: string } | null>(null);

  const submit = useMutation({
    mutationFn: () => {
      const fingerprint = `${stars}|${[...tags].sort().join(',')}|${comment}`;
      if (!intent.current || intent.current.fingerprint !== fingerprint) {
        intent.current = { key: newIdempotencyKey(), fingerprint };
      }
      return ratingRepository.submitRating({
        jobId,
        stars,
        tagKeys: [...tags],
        comment: comment.trim() === '' ? undefined : comment.trim(),
        idempotencyKey: intent.current.key,
      });
    },
    onSuccess: () => {
      intent.current = null;
      void queryClient.invalidateQueries({ queryKey: ['rating', jobId] });
    },
  });

  const toggleTag = (key: string) => {
    setTags((prev) => {
      const next = new Set(prev);
      if (next.has(key)) {
        next.delete(key);
      } else {
        next.add(key);
      }
      return next;
    });
  };

  if (myRatingQuery.isPending) {
    return <StateBlock variant="loading" />;
  }
  if (myRatingQuery.isError) {
    return (
      <StateBlock
        variant="error"
        errorMessage={errorText(dict, myRatingQuery.error)}
        retryLabel={dict.common.retry}
        onRetry={() => void myRatingQuery.refetch()}
      />
    );
  }
  if (myRatingQuery.data) {
    return <RatingSummary rating={myRatingQuery.data} dict={dict} />;
  }

  return (
    <div className="rounded-lg border border-outline bg-surface-raised p-xl dark:border-outline-dark dark:bg-surface-dark-raised">
      <h2 className="text-title-large text-ink-primary dark:text-ink-dark-primary">
        {dict.requests.rating.title}
      </h2>
      <div className="mt-md flex gap-xs" role="radiogroup" aria-label={dict.requests.rating.starsLabel}>
        {[1, 2, 3, 4, 5].map((value) => (
          <button
            key={value}
            type="button"
            role="radio"
            aria-checked={stars === value}
            onClick={() => setStars(value)}
            className={`text-headline-medium transition-colors duration-normal ease-standard ${
              value <= stars
                ? 'text-warning dark:text-warning-dark'
                : 'text-outline dark:text-outline-dark'
            }`}
          >
            {value <= stars ? '★' : '☆'}
          </button>
        ))}
      </div>
      <div className="mt-md flex flex-wrap gap-sm">
        {RATING_TAG_KEYS.map((key) => (
          <button
            key={key}
            type="button"
            aria-pressed={tags.has(key)}
            onClick={() => toggleTag(key)}
            className={`rounded-pill px-md py-xs text-body-small transition-colors duration-normal ease-standard ${
              tags.has(key)
                ? 'bg-brand-primary text-brand-on-primary'
                : 'border border-outline text-ink-primary hover:bg-surface-muted dark:border-outline-dark dark:text-ink-dark-primary dark:hover:bg-surface-dark-muted'
            }`}
          >
            {tagLabel(dict, key)}
          </button>
        ))}
      </div>
      <textarea
        rows={3}
        value={comment}
        onChange={(e) => setComment(e.target.value)}
        aria-label={dict.requests.rating.commentLabel}
        className="mt-md w-full rounded-md border border-outline bg-surface-raised px-md py-sm text-body-large text-ink-primary outline-none transition-colors duration-normal ease-standard focus:border-brand-primary dark:border-outline-dark dark:bg-surface-dark-raised dark:text-ink-dark-primary"
      />
      {submit.isError ? (
        <p role="alert" className="mt-sm text-body-small text-error dark:text-error-dark">
          {errorText(dict, submit.error)}
        </p>
      ) : null}
      <button
        type="button"
        disabled={stars === 0 || submit.isPending}
        onClick={() => submit.mutate()}
        className="mt-md rounded-md bg-brand-primary px-xl py-md text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong disabled:opacity-50"
      >
        {dict.requests.rating.submitCta}
      </button>
    </div>
  );
}
