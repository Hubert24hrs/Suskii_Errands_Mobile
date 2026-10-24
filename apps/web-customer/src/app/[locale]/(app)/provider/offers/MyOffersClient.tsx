'use client';

import { useRef, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import type { Dictionary } from '@/lib/i18n/en';
import type { Locale } from '@/lib/i18n';
import { offerRepository, providerRepository } from '@/lib/repositories';
import { newIdempotencyKey } from '@/lib/idempotency';
import { serverClockOffsetMs } from '@/lib/serverClock';
import type { Offer, OfferStatus } from '@/mocks/types';
import { CountdownTimer } from '@/components/CountdownTimer';
import { Modal } from '@/components/Modal';
import { MoneyField } from '@/components/MoneyField';
import { MoneyText } from '@/components/MoneyText';
import { StateBlock } from '@/components/StateBlock';
import { StatusChip } from '@/components/StatusChip';
import {
  Notice,
  ProviderPage,
  btnDanger,
  btnPrimary,
  btnSecondary,
  card,
  errorText,
  fill,
  formatDateTime,
  mutedText,
  pageTitle,
} from '../_shared';

function tone(status: OfferStatus) {
  switch (status) {
    case 'accepted':
      return 'success' as const;
    case 'countered':
      return 'warning' as const;
    case 'pending':
      return 'info' as const;
    default:
      return 'neutral' as const;
  }
}

export function MyOffersClient({ locale, dict }: { locale: Locale; dict: Dictionary }) {
  const t = dict.provider;
  const offers = useQuery({ queryKey: ['provider', 'offers'], queryFn: () => providerRepository.getMyOffers() });

  return (
    <ProviderPage locale={locale} dict={dict}>
      <h1 className={pageTitle}>{t.offers.title}</h1>
      {offers.isPending ? (
        <StateBlock variant="loading" />
      ) : offers.isError ? (
        <StateBlock
          variant="error"
          errorMessage={errorText(dict, offers.error)}
          retryLabel={dict.common.retry}
          onRetry={() => void offers.refetch()}
        />
      ) : offers.data.length === 0 ? (
        <StateBlock variant="empty" emptyTitle={t.offers.empty} />
      ) : (
        <ul className="flex flex-col gap-md" data-testid="my-offers">
          {offers.data.map((offer) => (
            <li key={offer.id}>
              <OfferCard offer={offer} dict={dict} />
            </li>
          ))}
        </ul>
      )}
    </ProviderPage>
  );
}

function OfferCard({ offer, dict }: { offer: Offer; dict: Dictionary }) {
  const t = dict.provider;
  const queryClient = useQueryClient();
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState<{ text: string; tone: 'success' | 'error' }>();
  const [counterOpen, setCounterOpen] = useState(false);
  const [counterAmount, setCounterAmount] = useState<number | null>(null);
  // One key per intent, kept across retries of that intent.
  const keys = useRef<Record<string, string>>({});
  const keyFor = (intent: string) => (keys.current[intent] ??= newIdempotencyKey());

  async function act(intent: string, run: (key: string) => Promise<unknown>, done?: string) {
    setBusy(true);
    setNotice(undefined);
    try {
      await run(keyFor(intent));
      delete keys.current[intent];
      if (done) setNotice({ text: done, tone: 'success' });
      setCounterOpen(false);
      await queryClient.invalidateQueries({ queryKey: ['provider', 'offers'] });
    } catch (error) {
      setNotice({ text: errorText(dict, error), tone: 'error' });
    } finally {
      setBusy(false);
    }
  }

  const live = offer.status === 'pending' || offer.status === 'countered';
  return (
    <div className={`${card} flex flex-col gap-sm`} data-testid={`my-offer-${offer.id}`}>
      <div className="flex flex-wrap items-center justify-between gap-sm">
        <MoneyText
          amountMinor={offer.amount.amountMinor}
          currency={offer.amount.currency}
          className="text-title-large text-ink-primary dark:text-ink-dark-primary"
        />
        <StatusChip label={(t.offers.statuses as Record<string, string>)[offer.status] ?? offer.status} tone={tone(offer.status)} />
      </div>
      {offer.status === 'countered' ? <p className={mutedText}>{t.offers.customerCountered}</p> : null}
      {offer.message ? <p className="text-body-medium text-ink-primary dark:text-ink-dark-primary">{offer.message}</p> : null}
      <div className="flex flex-wrap gap-md text-body-small text-ink-secondary dark:text-ink-dark-secondary">
        <span>{fill(t.offers.round, { round: offer.round })}</span>
        <span>{formatDateTime(offer.createdAt)}</span>
        {live && offer.expiresAt ? (
          <span>
            {t.offers.expiresIn}{' '}
            <CountdownTimer
              deadline={offer.expiresAt.toISOString()}
              clockOffsetMs={serverClockOffsetMs()}
              expiredLabel={t.offers.statuses.expired}
            />
          </span>
        ) : null}
      </div>
      {offer.status === 'countered' ? (
        <div className="flex flex-wrap gap-sm">
          <button
            type="button"
            data-testid={`offer-accept-${offer.id}`}
            disabled={busy}
            className={btnPrimary}
            onClick={() => void act('accept', (key) => offerRepository.acceptOffer(offer.id, key), t.offers.accepted)}
          >
            {t.offers.acceptCounter}
          </button>
          <button type="button" disabled={busy} className={btnSecondary} onClick={() => setCounterOpen(true)}>
            {t.offers.counter}
          </button>
          <button
            type="button"
            disabled={busy}
            className={btnDanger}
            onClick={() => void act('decline', (key) => offerRepository.declineOffer(offer.id, key))}
          >
            {t.offers.decline}
          </button>
        </div>
      ) : null}
      {offer.status === 'pending' ? (
        <div>
          <button
            type="button"
            disabled={busy}
            className={btnDanger}
            onClick={() => void act('withdraw', (key) => offerRepository.withdrawOffer(offer.id, key), t.offerSheet.withdrawn)}
          >
            {t.offerSheet.withdraw}
          </button>
        </div>
      ) : null}
      <Notice text={notice?.text} tone={notice?.tone} />
      <Modal open={counterOpen} onClose={() => setCounterOpen(false)} title={t.offers.counterTitle} closeLabel={dict.common.close}>
        <div className="flex flex-col gap-md">
          <MoneyField
            label={t.offers.counterAmount}
            currency={offer.amount.currency}
            valueMinor={counterAmount}
            onChange={setCounterAmount}
          />
          <button
            type="button"
            disabled={busy || counterAmount === null || counterAmount <= 0}
            className={btnPrimary}
            onClick={() =>
              void act(`counter:${counterAmount}`, (key) =>
                offerRepository.counterOffer({
                  offerId: offer.id,
                  amount: { amountMinor: counterAmount ?? 0, currency: offer.amount.currency },
                  idempotencyKey: key,
                }),
              )
            }
          >
            {t.offers.counterSend}
          </button>
        </div>
      </Modal>
    </div>
  );
}
