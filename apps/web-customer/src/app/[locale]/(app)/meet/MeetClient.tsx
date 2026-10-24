'use client';

// Suskii Meet: discover meet-ups near you, the ones you host or joined, and
// a form to host one in a public place. Mirrors apps/mobile/lib/features/meet.

import { useState } from 'react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import type { Dictionary } from '@/lib/i18n/en';
import type { Locale } from '@/lib/i18n';
import { newIdempotencyKey } from '@/lib/idempotency';
import { meetupRepository } from '@/lib/repositories';
import { MEETUP_TOPICS, type GeoPoint, type Meetup, type MeetupTopic } from '@/mocks/types';
import { StateBlock } from '@/components/StateBlock';
import { StatusChip } from '@/components/StatusChip';
import { errorText } from '../requests/_shared';
import {
  badge,
  card,
  currentPosition,
  fill,
  inputClasses,
  meetupWhen,
  primaryButton,
  secondaryButton,
} from './_shared';

type Tab = 'discover' | 'mine';

function MeetupCard({ locale, dict, m }: { locale: Locale; dict: Dictionary; m: Meetup }) {
  return (
    <li>
      <Link
        href={`/${locale}/meet/${m.id}`}
        data-testid={`meet-card-${m.id}`}
        className={`block ${card} transition-colors duration-normal ease-standard hover:border-brand-primary dark:hover:border-brand-secondary`}
      >
        <div className="flex flex-wrap items-start justify-between gap-md">
          <div className="min-w-0">
            <p className="text-label-small uppercase tracking-wide text-brand-primary dark:text-brand-secondary">
              {dict.meet.topics[m.topic]}
            </p>
            <h2 className="mt-xs text-title-large text-ink-primary dark:text-ink-dark-primary">
              {m.title}
            </h2>
          </div>
          <StatusChip label={badge(dict, m)} tone={m.status === 'cancelled' ? 'error' : 'info'} />
        </div>
        <p className="mt-sm text-body-medium text-ink-primary dark:text-ink-dark-primary">
          {meetupWhen(m.startsAt)}
        </p>
        <p className="text-body-small text-ink-secondary dark:text-ink-dark-secondary">
          {m.venueName}
          {m.distanceKm !== undefined
            ? ` · ${fill(dict.meet.distanceKm, { km: m.distanceKm.toFixed(1) })}`
            : ''}
        </p>
        <p className="mt-sm text-body-small text-ink-secondary dark:text-ink-dark-secondary">
          {fill(dict.meet.going, { count: m.attendeeCount })} ·{' '}
          {fill(dict.meet.hostedBy, { name: m.hostFirstName })}
        </p>
      </Link>
    </li>
  );
}

function defaultStart(): string {
  const d = new Date(Date.now() + 24 * 3_600_000);
  d.setHours(10, 0, 0, 0);
  // datetime-local wants local wall time without a zone.
  const pad = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

function CreateForm({ locale, dict }: { locale: Locale; dict: Dictionary }) {
  const router = useRouter();
  const queryClient = useQueryClient();
  const [title, setTitle] = useState('');
  const [description, setDescription] = useState('');
  const [topic, setTopic] = useState<MeetupTopic>('social');
  const [venueName, setVenueName] = useState('');
  const [venue, setVenue] = useState<GeoPoint | undefined>();
  const [start, setStart] = useState(defaultStart);
  const [hours, setHours] = useState(2);
  const [capacity, setCapacity] = useState(10);
  const [key, setKey] = useState(() => newIdempotencyKey());
  const [error, setError] = useState<string | null>(null);
  const [locating, setLocating] = useState(false);

  const edited = () => {
    setKey(newIdempotencyKey());
    setError(null);
  };

  const create = useMutation({
    mutationFn: () => {
      if (!venue) throw new Error('venue');
      const startsAt = new Date(start);
      return meetupRepository.createMeetup(
        {
          title: title.trim(),
          description: description.trim(),
          topic,
          venueName: venueName.trim(),
          venue,
          startsAt: startsAt.toISOString(),
          endsAt: new Date(startsAt.getTime() + hours * 3_600_000).toISOString(),
          capacity,
        },
        key,
      );
    },
    onSuccess: (id) => {
      void queryClient.invalidateQueries({ queryKey: ['meetups'] });
      router.push(`/${locale}/meet/${id}`);
    },
    onError: (e) => setError(errorText(dict, e)),
  });

  async function locate() {
    setLocating(true);
    const point = await currentPosition();
    setLocating(false);
    setVenue(point);
    setKey(newIdempotencyKey());
    setError(point ? null : dict.meet.formLocationFailed);
  }

  const ready = title.trim().length >= 3 && venueName.trim().length >= 2 && !create.isPending;

  return (
    <form
      className={`${card} flex flex-col gap-lg`}
      onSubmit={(e) => {
        e.preventDefault();
        if (!venue) {
          setError(dict.meet.formLocationNeeded);
          return;
        }
        create.mutate();
      }}
    >
      <h2 className="text-title-large text-ink-primary dark:text-ink-dark-primary">{dict.meet.create}</h2>
      <label className="flex flex-col gap-xs text-label-large text-ink-primary dark:text-ink-dark-primary">
        {dict.meet.formTitle}
        <input
          className={inputClasses}
          value={title}
          maxLength={80}
          data-testid="meet-title"
          onChange={(e) => {
            setTitle(e.target.value);
            edited();
          }}
        />
      </label>
      <label className="flex flex-col gap-xs text-label-large text-ink-primary dark:text-ink-dark-primary">
        {dict.meet.formDescription}
        <textarea
          className={inputClasses}
          rows={3}
          maxLength={1000}
          value={description}
          onChange={(e) => {
            setDescription(e.target.value);
            edited();
          }}
        />
      </label>
      <label className="flex flex-col gap-xs text-label-large text-ink-primary dark:text-ink-dark-primary">
        {dict.meet.formTopic}
        <select
          className={inputClasses}
          value={topic}
          onChange={(e) => {
            setTopic(e.target.value as MeetupTopic);
            edited();
          }}
        >
          {MEETUP_TOPICS.map((t) => (
            <option key={t} value={t}>
              {dict.meet.topics[t]}
            </option>
          ))}
        </select>
      </label>
      <label className="flex flex-col gap-xs text-label-large text-ink-primary dark:text-ink-dark-primary">
        {dict.meet.formVenue}
        <input
          className={inputClasses}
          value={venueName}
          maxLength={120}
          placeholder={dict.meet.formVenueHint}
          data-testid="meet-venue"
          onChange={(e) => {
            setVenueName(e.target.value);
            edited();
          }}
        />
      </label>
      <button
        type="button"
        className={secondaryButton}
        onClick={() => void locate()}
        disabled={locating}
        data-testid="meet-locate"
      >
        {venue ? `✓ ${dict.meet.formLocationSet}` : dict.meet.formUseMyLocation}
      </button>
      <div className="grid gap-lg sm:grid-cols-3">
        <label className="flex flex-col gap-xs text-label-large text-ink-primary dark:text-ink-dark-primary">
          {dict.meet.formStart}
          <input
            type="datetime-local"
            className={inputClasses}
            value={start}
            onChange={(e) => {
              setStart(e.target.value);
              edited();
            }}
          />
        </label>
        <label className="flex flex-col gap-xs text-label-large text-ink-primary dark:text-ink-dark-primary">
          {dict.meet.formDuration}
          <select
            className={inputClasses}
            value={hours}
            onChange={(e) => {
              setHours(Number(e.target.value));
              edited();
            }}
          >
            {[1, 2, 3, 4, 6, 8].map((h) => (
              <option key={h} value={h}>
                {h}
              </option>
            ))}
          </select>
        </label>
        <label className="flex flex-col gap-xs text-label-large text-ink-primary dark:text-ink-dark-primary">
          {dict.meet.formCapacity}
          <input
            type="number"
            min={2}
            max={500}
            className={inputClasses}
            value={capacity}
            onChange={(e) => {
              setCapacity(Number(e.target.value));
              edited();
            }}
          />
        </label>
      </div>
      <p className="text-body-small text-ink-secondary dark:text-ink-dark-secondary">{dict.meet.safetyBody}</p>
      {error ? (
        <p role="alert" className="text-body-medium text-error dark:text-error-dark">
          {error}
        </p>
      ) : null}
      <button type="submit" className={primaryButton} disabled={!ready} data-testid="meet-publish">
        {dict.meet.formPublish}
      </button>
    </form>
  );
}

export function MeetClient({ locale, dict }: { locale: Locale; dict: Dictionary }) {
  const [tab, setTab] = useState<Tab>('discover');
  const [creating, setCreating] = useState(false);

  const near = useQuery({ queryKey: ['meetups', 'near'], queryFn: currentPosition, staleTime: 300_000 });
  const discover = useQuery({
    queryKey: ['meetups', 'list', near.data?.latitude, near.data?.longitude],
    queryFn: () => meetupRepository.listMeetups({ near: near.data }),
    enabled: tab === 'discover' && !near.isPending,
  });
  const mine = useQuery({
    queryKey: ['meetups', 'mine'],
    queryFn: () => meetupRepository.myMeetups(),
    enabled: tab === 'mine',
  });
  const query = tab === 'discover' ? discover : mine;

  return (
    <div className="mx-auto w-full max-w-3xl px-lg py-xxxl">
      <div className="flex flex-wrap items-end justify-between gap-md">
        <div>
          <h1 className="text-headline-medium text-ink-primary dark:text-ink-dark-primary">{dict.meet.title}</h1>
          <p className="mt-xs text-body-large text-ink-secondary dark:text-ink-dark-secondary">
            {dict.meet.subtitle}
          </p>
        </div>
        <button type="button" className={primaryButton} onClick={() => setCreating((c) => !c)} data-testid="meet-create">
          {dict.meet.create}
        </button>
      </div>

      {creating ? (
        <div className="mt-xl">
          <CreateForm locale={locale} dict={dict} />
        </div>
      ) : null}

      <div className={`mt-xl ${card}`}>
        <p className="text-title-medium text-ink-primary dark:text-ink-dark-primary">{dict.meet.safetyTitle}</p>
        <p className="mt-xs text-body-small text-ink-secondary dark:text-ink-dark-secondary">{dict.meet.safetyBody}</p>
      </div>

      <div className="mt-xl flex rounded-md border border-outline p-xs dark:border-outline-dark" role="tablist">
        {(['discover', 'mine'] as const).map((t) => (
          <button
            key={t}
            type="button"
            role="tab"
            aria-selected={tab === t}
            onClick={() => setTab(t)}
            className={`flex-1 rounded-sm px-md py-xs text-label-large ${
              tab === t
                ? 'bg-brand-primary text-brand-on-primary'
                : 'text-ink-secondary hover:text-ink-primary dark:text-ink-dark-secondary dark:hover:text-ink-dark-primary'
            }`}
          >
            {t === 'discover' ? dict.meet.tabDiscover : dict.meet.tabMine}
          </button>
        ))}
      </div>

      <div className="mt-xl">
        {query.isPending || (tab === 'discover' && near.isPending) ? (
          <StateBlock variant="loading" />
        ) : query.isError ? (
          <StateBlock
            variant="error"
            errorMessage={errorText(dict, query.error)}
            retryLabel={dict.common.retry}
            onRetry={() => void query.refetch()}
          />
        ) : query.data.length === 0 ? (
          <StateBlock
            variant="empty"
            emptyTitle={tab === 'discover' ? dict.meet.emptyTitle : dict.meet.mineEmpty}
            emptyBody={tab === 'discover' ? dict.meet.emptyBody : undefined}
          />
        ) : (
          <ul className="flex flex-col gap-lg">
            {query.data.map((m) => (
              <MeetupCard key={m.id} locale={locale} dict={dict} m={m} />
            ))}
          </ul>
        )}
      </div>
    </div>
  );
}
