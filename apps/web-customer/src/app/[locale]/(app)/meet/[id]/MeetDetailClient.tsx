'use client';

// One meet-up: what, when, where, who is going (for the host and the people
// going only), and the action that fits — join, leave or cancel.

import { useState } from 'react';
import Link from 'next/link';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import type { Dictionary } from '@/lib/i18n/en';
import type { Locale } from '@/lib/i18n';
import { newIdempotencyKey } from '@/lib/idempotency';
import { meetupRepository } from '@/lib/repositories';
import { StateBlock } from '@/components/StateBlock';
import { errorText } from '../../requests/_shared';
import { card, fill, meetupWhen, primaryButton, secondaryButton, spotsLeft } from '../_shared';

export function MeetDetailClient({
  locale,
  dict,
  meetupId,
}: {
  locale: Locale;
  dict: Dictionary;
  meetupId: string;
}) {
  const queryClient = useQueryClient();
  // One key per intent, so a retry after a lost response is the same join
  // or cancel on the server.
  const [joinKey, setJoinKey] = useState(() => newIdempotencyKey());
  const [cancelKey] = useState(() => newIdempotencyKey());
  const [confirming, setConfirming] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const meetup = useQuery({
    queryKey: ['meetups', 'one', meetupId],
    queryFn: () => meetupRepository.getMeetup(meetupId),
  });
  const m = meetup.data;
  const canSee = !!m && (m.isHost || m.isAttending);
  const attendees = useQuery({
    queryKey: ['meetups', 'attendees', meetupId, canSee],
    queryFn: () => meetupRepository.attendees(meetupId),
    enabled: canSee,
  });

  const refresh = () => void queryClient.invalidateQueries({ queryKey: ['meetups'] });
  const onError = (e: unknown) => setError(errorText(dict, e));

  const join = useMutation({
    mutationFn: () => meetupRepository.joinMeetup(meetupId, joinKey),
    onSuccess: () => {
      setJoinKey(newIdempotencyKey());
      setError(null);
      refresh();
    },
    onError,
  });
  const leave = useMutation({
    mutationFn: () => meetupRepository.leaveMeetup(meetupId),
    onSuccess: refresh,
    onError,
  });
  const cancel = useMutation({
    mutationFn: () => meetupRepository.cancelMeetup(meetupId, cancelKey),
    onSuccess: () => {
      setConfirming(false);
      refresh();
    },
    onError,
  });
  const busy = join.isPending || leave.isPending || cancel.isPending;

  return (
    <div className="mx-auto w-full max-w-3xl px-lg py-xxxl">
      <Link href={`/${locale}/meet`} className="text-label-large text-brand-primary hover:underline">
        ← {dict.meet.back}
      </Link>
      <div className="mt-lg">
        {meetup.isPending ? (
          <StateBlock variant="loading" />
        ) : meetup.isError ? (
          <StateBlock
            variant="error"
            errorMessage={errorText(dict, meetup.error)}
            retryLabel={dict.common.retry}
            onRetry={() => void meetup.refetch()}
          />
        ) : (
          (() => {
            const now = Date.now();
            const mm = meetup.data;
            const cancelled = mm.status === 'cancelled';
            const full = mm.attendeeCount >= mm.capacity;
            const canJoin =
              !mm.isHost && !mm.isAttending && !cancelled && !full && Date.parse(mm.startsAt) > now;
            return (
              <article className={`${card} flex flex-col gap-md`}>
                <p className="text-label-small uppercase tracking-wide text-brand-primary dark:text-brand-secondary">
                  {dict.meet.topics[mm.topic]}
                </p>
                <h1 className="text-headline-medium text-ink-primary dark:text-ink-dark-primary">{mm.title}</h1>
                <p className="text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
                  {fill(dict.meet.hostedBy, { name: mm.hostFirstName })}
                </p>
                {cancelled ? (
                  <p className="text-title-medium text-error dark:text-error-dark">{dict.meet.cancelled}</p>
                ) : null}
                <dl className="grid gap-sm text-body-medium text-ink-primary dark:text-ink-dark-primary">
                  <div>🕒 {meetupWhen(mm.startsAt)}</div>
                  <div>📍 {mm.venueName}</div>
                  <div>
                    👥 {fill(dict.meet.going, { count: mm.attendeeCount })} ·{' '}
                    {full ? dict.meet.full : fill(dict.meet.spotsLeft, { count: spotsLeft(mm) })}
                  </div>
                </dl>
                {mm.description ? (
                  <p className="text-body-large text-ink-primary dark:text-ink-dark-primary">{mm.description}</p>
                ) : null}
                {error ? (
                  <p role="alert" className="text-body-medium text-error dark:text-error-dark">
                    {error}
                  </p>
                ) : null}
                <div className="flex flex-wrap gap-md">
                  {canJoin ? (
                    <button
                      type="button"
                      className={primaryButton}
                      disabled={busy}
                      onClick={() => join.mutate()}
                      data-testid="meet-join"
                    >
                      {dict.meet.join}
                    </button>
                  ) : mm.isAttending && !cancelled ? (
                    <button
                      type="button"
                      className={secondaryButton}
                      disabled={busy}
                      onClick={() => leave.mutate()}
                      data-testid="meet-leave"
                    >
                      {dict.meet.leave}
                    </button>
                  ) : mm.isHost && !cancelled && Date.parse(mm.endsAt) > now ? (
                    confirming ? (
                      <div className="flex flex-col gap-sm">
                        <p className="text-body-medium text-ink-primary dark:text-ink-dark-primary">
                          {dict.meet.cancelConfirm}
                        </p>
                        <div className="flex gap-md">
                          <button
                            type="button"
                            className={primaryButton}
                            disabled={busy}
                            onClick={() => cancel.mutate()}
                            data-testid="meet-cancel-confirm"
                          >
                            {dict.meet.cancel}
                          </button>
                          <button type="button" className={secondaryButton} onClick={() => setConfirming(false)}>
                            {dict.meet.back}
                          </button>
                        </div>
                      </div>
                    ) : (
                      <button
                        type="button"
                        className={secondaryButton}
                        onClick={() => setConfirming(true)}
                        data-testid="meet-cancel"
                      >
                        {dict.meet.cancel}
                      </button>
                    )
                  ) : null}
                </div>
                {canSee ? (
                  <section className="mt-md">
                    <h2 className="text-title-medium text-ink-primary dark:text-ink-dark-primary">
                      {dict.meet.attendees}
                    </h2>
                    <ul className="mt-sm flex flex-wrap gap-sm">
                      {(attendees.data ?? []).map((a, i) => (
                        <li
                          key={`${a.firstName}-${i}`}
                          className="rounded-pill border border-outline px-md py-xs text-label-large text-ink-primary dark:border-outline-dark dark:text-ink-dark-primary"
                        >
                          {a.isHost ? '★ ' : ''}
                          {a.firstName}
                        </li>
                      ))}
                    </ul>
                  </section>
                ) : null}
                <p className="text-body-small text-ink-secondary dark:text-ink-dark-secondary">{dict.meet.safetyBody}</p>
              </article>
            );
          })()
        )}
      </div>
    </div>
  );
}
