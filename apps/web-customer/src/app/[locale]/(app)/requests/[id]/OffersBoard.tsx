'use client';

import { useEffect, useMemo, useRef, useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import type { Dictionary } from '@/lib/i18n/en';
import { newIdempotencyKey } from '@/lib/idempotency';
import { serverClockOffsetMs } from '@/lib/serverClock';
import {
  catalogRepository,
  isAppError,
  offerRepository,
} from '@/lib/repositories';
import type { JobRequest, Offer } from '@/mocks/types';
import { CountdownTimer } from '@/components/CountdownTimer';
import { Modal } from '@/components/Modal';
import { MoneyField } from '@/components/MoneyField';
import { MoneyText } from '@/components/MoneyText';
import { StateBlock } from '@/components/StateBlock';
import { StatusChip } from '@/components/StatusChip';
import { errorText } from '../_shared';

function offerStatusLabel(dict: Dictionary, status: Offer['status']): string {
  const table = dict.offers.statuses as Record<string, string>;
  return table[status] ?? status;
}

function OfferCard({
  offer,
  dict,
  clockOffsetMs,
  maxRounds,
}: {
  offer: Offer;
  dict: Dictionary;
  clockOffsetMs: number;
  maxRounds: number;
}) {
  // One idempotency key per offer-action intent; reused on retry, regenerated
  // after success or when the counter inputs change.
  const actionKeys = useRef<Record<string, string>>({});
  const keyFor = (action: string) =>
    (actionKeys.current[action] ??= newIdempotencyKey());

  const [counterOpen, setCounterOpen] = useState(false);
  const [counterAmountMinor, setCounterAmountMinor] = useState<number | null>(null);
  const [counterMessage, setCounterMessage] = useState('');
  const [actionError, setActionError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const actionable = offer.status === 'pending';
  const greyed =
    offer.status === 'expired' ||
    offer.status === 'withdrawn' ||
    offer.status === 'declined';
  const roundsLeft = offer.round < maxRounds;

  const run = async (action: () => Promise<unknown>, keyName: string): Promise<boolean> => {
    setBusy(true);
    setActionError(null);
    try {
      await action();
      delete actionKeys.current[keyName];
      return true;
    } catch (error) {
      if (isAppError(error, 'ERR_OFFER_NOT_ACTIVE')) {
        setActionError(dict.offers.anotherProviderSelected);
      } else {
        setActionError(errorText(dict, error));
      }
      return false;
    } finally {
      setBusy(false);
    }
  };

  const submitCounter = async () => {
    if (counterAmountMinor === null || counterAmountMinor <= 0) return;
    const ok = await run(
      () =>
        offerRepository.counterOffer({
          offerId: offer.id,
          amount: { amountMinor: counterAmountMinor, currency: offer.amount.currency },
          message: counterMessage.trim() === '' ? undefined : counterMessage.trim(),
          idempotencyKey: keyFor(`counter:${counterAmountMinor}:${counterMessage}`),
        }),
      `counter:${counterAmountMinor}:${counterMessage}`,
    );
    if (ok) setCounterOpen(false);
  };

  return (
    <li
      className={`rounded-lg border border-outline bg-surface-raised p-xl dark:border-outline-dark dark:bg-surface-dark-raised ${
        greyed ? 'opacity-60' : ''
      }`}
    >
      <div className="flex flex-wrap items-center justify-between gap-md">
        <div>
          <p className="text-title-large text-ink-primary dark:text-ink-dark-primary">
            {offer.providerName}
          </p>
          <p className="text-body-small text-ink-secondary dark:text-ink-dark-secondary">
            ★ {offer.providerRating} · {offer.providerTrustLevel}
          </p>
        </div>
        <StatusChip
          label={offerStatusLabel(dict, offer.status)}
          tone={
            offer.status === 'accepted'
              ? 'success'
              : actionable || offer.status === 'countered'
                ? 'info'
                : 'neutral'
          }
        />
      </div>

      <div className="mt-md flex flex-wrap items-baseline justify-between gap-md">
        <MoneyText
          amountMinor={offer.amount.amountMinor}
          currency={offer.amount.currency}
          className="text-headline-medium text-ink-primary dark:text-ink-dark-primary"
        />
        <span className="text-body-small text-ink-secondary dark:text-ink-dark-secondary">
          {dict.offers.roundLabel} {offer.round}/{maxRounds}
        </span>
      </div>

      {offer.message ? (
        <p className="mt-sm text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
          {offer.message}
        </p>
      ) : null}

      {offer.payoutEstimate ? (
        <p className="mt-sm text-body-small text-ink-secondary dark:text-ink-dark-secondary">
          {dict.offers.payoutEstimateLabel}:{' '}
          <MoneyText
            amountMinor={offer.payoutEstimate.providerPayout.amountMinor}
            currency={offer.payoutEstimate.providerPayout.currency}
          />{' '}
          — {dict.offers.payoutEstimateNote}
        </p>
      ) : null}

      {offer.expiresAt && (actionable || offer.status === 'countered') ? (
        <p className="mt-sm text-body-small text-ink-secondary dark:text-ink-dark-secondary">
          {dict.offers.expiresInLabel}:{' '}
          <CountdownTimer
            deadline={offer.expiresAt.toISOString()}
            clockOffsetMs={clockOffsetMs}
            expiredLabel={dict.offers.expired}
          />
        </p>
      ) : null}

      {actionError ? (
        <p role="alert" className="mt-sm text-body-small text-error dark:text-error-dark">
          {actionError}
        </p>
      ) : null}

      {actionable ? (
        <div className="mt-lg flex flex-wrap gap-sm">
          <button
            type="button"
            disabled={busy}
            onClick={() =>
              void run(
                () => offerRepository.acceptOffer(offer.id, keyFor('accept')),
                'accept',
              )
            }
            className="rounded-md bg-brand-primary px-lg py-sm text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong disabled:opacity-50"
          >
            {dict.offers.accept}
          </button>
          {roundsLeft ? (
            <button
              type="button"
              disabled={busy}
              onClick={() => {
                setActionError(null);
                setCounterOpen(true);
              }}
              className="rounded-md border border-outline px-lg py-sm text-label-large text-ink-primary transition-colors duration-normal ease-standard hover:bg-surface-muted disabled:opacity-50 dark:border-outline-dark dark:text-ink-dark-primary dark:hover:bg-surface-dark-muted"
            >
              {dict.offers.counter}
            </button>
          ) : null}
          <button
            type="button"
            disabled={busy}
            onClick={() =>
              void run(
                () => offerRepository.declineOffer(offer.id, keyFor('decline')),
                'decline',
              )
            }
            className="rounded-md px-lg py-sm text-label-large text-ink-secondary transition-colors duration-normal ease-standard hover:text-ink-primary disabled:opacity-50 dark:text-ink-dark-secondary dark:hover:text-ink-dark-primary"
          >
            {dict.offers.decline}
          </button>
        </div>
      ) : null}

      <Modal
        open={counterOpen}
        onClose={() => setCounterOpen(false)}
        title={dict.offers.counterTitle}
        closeLabel={dict.common.close}
      >
        <div className="flex flex-col gap-lg">
          <MoneyField
            label={dict.offers.counterAmountLabel}
            currency={offer.amount.currency}
            valueMinor={counterAmountMinor}
            onChange={setCounterAmountMinor}
          />
          <div className="flex flex-col gap-xs">
            <label
              htmlFor={`counter-message-${offer.id}`}
              className="text-label-large text-ink-primary dark:text-ink-dark-primary"
            >
              {dict.offers.counterMessageLabel}
            </label>
            <textarea
              id={`counter-message-${offer.id}`}
              rows={3}
              value={counterMessage}
              onChange={(e) => setCounterMessage(e.target.value)}
              className="rounded-md border border-outline bg-surface-raised px-md py-sm text-body-large text-ink-primary outline-none transition-colors duration-normal ease-standard focus:border-brand-primary dark:border-outline-dark dark:bg-surface-dark-raised dark:text-ink-dark-primary"
            />
          </div>
          <button
            type="button"
            disabled={busy || counterAmountMinor === null || counterAmountMinor <= 0}
            onClick={() => void submitCounter()}
            className="rounded-md bg-brand-primary px-xl py-md text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong disabled:opacity-50"
          >
            {dict.offers.counterSend}
          </button>
        </div>
      </Modal>
    </li>
  );
}

export function OffersBoard({ job, dict }: { job: JobRequest; dict: Dictionary }) {
  // Captured once — the offset is fixed for the session after bootstrap.
  const clockOffsetMs = useMemo(() => serverClockOffsetMs(), []);

  const [offers, setOffers] = useState<Offer[] | undefined>(undefined);
  useEffect(() => {
    const unsubscribe = offerRepository.watchOffers(job.id, setOffers);
    return unsubscribe;
  }, [job.id]);

  const categoriesQuery = useQuery({
    queryKey: ['catalog', 'categories'],
    queryFn: () => catalogRepository.getCategories(),
  });
  const category = categoriesQuery.data?.find((c) => c.id === job.categoryId);
  const maxRounds = category?.maxCounterRounds ?? 1;

  return (
    <section className="mt-xxl">
      <h2 className="text-title-large text-ink-primary dark:text-ink-dark-primary">
        {dict.offers.title}
      </h2>
      <div className="mt-lg">
        {offers === undefined ? (
          <StateBlock variant="loading" />
        ) : offers.length === 0 ? (
          <StateBlock
            variant="empty"
            emptyTitle={dict.offers.emptyTitle}
            emptyBody={dict.offers.emptyBody}
          />
        ) : (
          <ul className="flex flex-col gap-lg">
            {offers.map((offer) => (
              <OfferCard
                key={offer.id}
                offer={offer}
                dict={dict}
                clockOffsetMs={clockOffsetMs}
                maxRounds={maxRounds}
              />
            ))}
          </ul>
        )}
      </div>
    </section>
  );
}
