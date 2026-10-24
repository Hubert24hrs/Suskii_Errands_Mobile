'use client';

import Link from 'next/link';
import { useEffect, useRef, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import type { Dictionary } from '@/lib/i18n/en';
import type { Locale } from '@/lib/i18n';
import {
  bootstrapRepository,
  catalogRepository,
  offerRepository,
  providerRepository,
} from '@/lib/repositories';
import { newIdempotencyKey } from '@/lib/idempotency';
import type { JobRequest, Offer, ServiceCategory } from '@/mocks/types';
import { Modal } from '@/components/Modal';
import { MoneyField } from '@/components/MoneyField';
import { MoneyText } from '@/components/MoneyText';
import { StateBlock } from '@/components/StateBlock';
import { StatusChip } from '@/components/StatusChip';
import { DashboardHeader } from './DashboardHeader';
import {
  ProviderPage,
  Notice,
  btnPrimary,
  btnSecondary,
  btnDanger,
  card,
  categoryLabel,
  errorText,
  fill,
  formatDateTime,
  inputClass,
  labelClass,
  mutedText,
  pageTitle,
  sectionTitle,
  urgencyLabel,
} from './_shared';

export function ProviderFeedClient({ locale, dict }: { locale: Locale; dict: Dictionary }) {
  const t = dict.provider;
  const queryClient = useQueryClient();
  const [toggling, setToggling] = useState(false);
  const [toggleError, setToggleError] = useState<string>();
  const [nearby, setNearby] = useState<JobRequest[] | undefined>(undefined);
  const [selected, setSelected] = useState<JobRequest | undefined>(undefined);

  const summary = useQuery({ queryKey: ['provider', 'home'], queryFn: () => providerRepository.getHomeSummary() });
  const categories = useQuery({ queryKey: ['catalog', 'categories'], queryFn: () => catalogRepository.getCategories() });

  useEffect(() => providerRepository.watchNearbyRequests(setNearby), []);

  async function setOnline(online: boolean) {
    setToggling(true);
    setToggleError(undefined);
    try {
      await providerRepository.setOnline(online, newIdempotencyKey());
      await queryClient.invalidateQueries({ queryKey: ['provider', 'home'] });
    } catch (error) {
      setToggleError(errorText(dict, error));
    } finally {
      setToggling(false);
    }
  }

  const data = summary.data;
  const verifying = data && (data.verificationStatus === 'pending' || data.verificationStatus === 'in_review');
  const unverified = data && !verifying && data.verificationStatus !== 'verified';

  return (
    <ProviderPage locale={locale} dict={dict}>
      <h1 className={pageTitle}>{t.feed.title}</h1>
      <DashboardHeader locale={locale} dict={dict} />

      {summary.isPending ? (
        <StateBlock variant="loading" />
      ) : summary.isError ? (
        <StateBlock
          variant="error"
          errorMessage={errorText(dict, summary.error)}
          retryLabel={dict.common.retry}
          onRetry={() => void summary.refetch()}
        />
      ) : data ? (
        <div className="flex flex-col gap-lg">
          {verifying ? <div className={`${card} text-body-medium`}>{t.feed.verificationPending}</div> : null}
          {unverified ? (
            <div className={`${card} flex flex-wrap items-center justify-between gap-md`}>
              <p className="text-body-medium text-ink-primary dark:text-ink-dark-primary">{t.feed.verificationNeeded}</p>
              <Link href={`/${locale}/provider/verification`} className={btnPrimary}>
                {t.nav.verification}
              </Link>
            </div>
          ) : null}
          <div className="grid gap-lg sm:grid-cols-2">
            <div className={`${card} flex flex-col gap-md`} data-testid="provider-online-card">
              <div className="flex items-center gap-sm">
                <span
                  aria-hidden
                  className={`inline-block h-3 w-3 rounded-pill ${data.online ? 'bg-success dark:bg-success-dark' : 'bg-outline dark:bg-outline-dark'}`}
                />
                <span className={sectionTitle} data-testid="provider-online-state">
                  {data.online ? t.feed.online : t.feed.offline}
                </span>
              </div>
              <button
                type="button"
                data-testid="provider-online-toggle"
                disabled={toggling}
                onClick={() => void setOnline(!data.online)}
                className={data.online ? btnSecondary : btnPrimary}
              >
                {data.online ? t.feed.goOffline : t.feed.goOnline}
              </button>
              <Notice text={toggleError} tone="error" />
            </div>
            <div className={`${card} flex flex-col gap-xs`}>
              <span className={mutedText}>{t.feed.todayEarnings}</span>
              <MoneyText
                amountMinor={data.todayEarnings.amountMinor}
                currency={data.todayEarnings.currency}
                className="text-headline-medium text-ink-primary dark:text-ink-dark-primary"
              />
              <span className={mutedText}>
                {data.completedToday} {t.feed.completedToday}
              </span>
            </div>
          </div>
          {data.documentWarnings.length > 0 ? (
            <section className="flex flex-col gap-sm">
              <h2 className={sectionTitle}>{t.feed.docWarnings}</h2>
              {data.documentWarnings.map((w) => (
                <div key={w.documentTypeKey} className={`${card} text-body-medium text-warning dark:text-warning-dark`}>
                  {fill(t.feed.docExpiry, {
                    document: (t.documents as Record<string, string>)[w.documentTypeKey] ?? w.documentTypeKey,
                    days: w.daysRemaining,
                  })}
                </div>
              ))}
            </section>
          ) : null}
        </div>
      ) : null}

      <section className="flex flex-col gap-md">
        <h2 className={sectionTitle}>{t.feed.nearby}</h2>
        {nearby === undefined ? (
          <StateBlock variant="loading" />
        ) : nearby.length === 0 ? (
          <StateBlock variant="empty" emptyTitle={t.feed.nearbyEmpty} />
        ) : (
          <ul className="flex flex-col gap-md" data-testid="provider-feed">
            {nearby.map((request) => (
              <li key={request.id}>
                <button
                  type="button"
                  data-testid={`feed-${request.id}`}
                  onClick={() => setSelected(request)}
                  className={`${card} w-full text-left transition-colors hover:border-brand-primary dark:hover:border-brand-secondary`}
                >
                  <div className="flex flex-wrap items-center justify-between gap-sm">
                    <span className="text-label-large text-ink-secondary dark:text-ink-dark-secondary">
                      {categoryLabel(dict, categories.data ?? [], request.categoryId)}
                    </span>
                    <StatusChip label={urgencyLabel(dict, request.urgency)} tone={request.urgency === 'standard' ? 'neutral' : 'warning'} />
                  </div>
                  <p className="mt-sm text-body-large text-ink-primary dark:text-ink-dark-primary">{request.description}</p>
                  <div className="mt-sm flex flex-wrap gap-md text-body-small text-ink-secondary dark:text-ink-dark-secondary">
                    <span>{request.pickup.label}</span>
                    {request.preferredPrice ? (
                      <span>
                        {t.feed.budget}:{' '}
                        <MoneyText amountMinor={request.preferredPrice.amountMinor} currency={request.preferredPrice.currency} />
                      </span>
                    ) : null}
                    <span>
                      {t.feed.posted} {formatDateTime(request.createdAt)}
                    </span>
                  </div>
                </button>
              </li>
            ))}
          </ul>
        )}
      </section>

      {selected ? (
        <FeedRequestModal
          request={selected}
          categories={categories.data ?? []}
          dict={dict}
          onClose={() => setSelected(undefined)}
        />
      ) : null}
    </ProviderPage>
  );
}

function FeedRequestModal({
  request,
  categories,
  dict,
  onClose,
}: {
  request: JobRequest;
  categories: ServiceCategory[];
  dict: Dictionary;
  onClose: () => void;
}) {
  const t = dict.provider;
  const queryClient = useQueryClient();
  const bootstrap = useQuery({ queryKey: ['bootstrap'], queryFn: () => bootstrapRepository.getBootstrap() });
  const myOffers = useQuery({ queryKey: ['provider', 'offers'], queryFn: () => providerRepository.getMyOffers() });
  const currency = request.preferredPrice?.currency ?? bootstrap.data?.countryPack.currencyCode ?? 'NGN';
  const [amount, setAmount] = useState<number | null>(request.preferredPrice?.amountMinor ?? null);
  const [message, setMessage] = useState('');
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState<{ text: string; tone: 'success' | 'error' }>();
  // One key per intent: a retry after a failure must replay, not create a second offer.
  const offerKey = useRef<string>(undefined);
  const withdrawKey = useRef<string>(undefined);

  const mine: Offer | undefined = myOffers.data?.find(
    (o) => o.requestId === request.id && (o.status === 'pending' || o.status === 'countered'),
  );

  async function send() {
    if (amount === null || amount <= 0) return;
    setBusy(true);
    setNotice(undefined);
    offerKey.current ??= newIdempotencyKey();
    try {
      await providerRepository.submitOffer({
        requestId: request.id,
        amount: { amountMinor: amount, currency },
        idempotencyKey: offerKey.current,
        message: message.trim() || undefined,
      });
      offerKey.current = undefined;
      setNotice({ text: t.offerSheet.sent, tone: 'success' });
      await queryClient.invalidateQueries({ queryKey: ['provider', 'offers'] });
    } catch (error) {
      setNotice({ text: errorText(dict, error), tone: 'error' });
    } finally {
      setBusy(false);
    }
  }

  async function withdraw(offer: Offer) {
    setBusy(true);
    setNotice(undefined);
    withdrawKey.current ??= newIdempotencyKey();
    try {
      await offerRepository.withdrawOffer(offer.id, withdrawKey.current);
      withdrawKey.current = undefined;
      setNotice({ text: t.offerSheet.withdrawn, tone: 'success' });
      await queryClient.invalidateQueries({ queryKey: ['provider', 'offers'] });
    } catch (error) {
      setNotice({ text: errorText(dict, error), tone: 'error' });
    } finally {
      setBusy(false);
    }
  }

  return (
    <Modal open onClose={onClose} title={categoryLabel(dict, categories, request.categoryId)} closeLabel={dict.common.close}>
      <div className="flex flex-col gap-md" data-testid="feed-request-modal">
        <p className="text-body-large text-ink-primary dark:text-ink-dark-primary">{request.description}</p>
        <dl className="grid grid-cols-[auto_1fr] gap-x-lg gap-y-xs text-body-medium">
          <dt className={mutedText}>{dict.requests.detail.pickup}</dt>
          <dd className="text-ink-primary dark:text-ink-dark-primary">{request.pickup.label}</dd>
          <dt className={mutedText}>{dict.requests.detail.urgency}</dt>
          <dd className="text-ink-primary dark:text-ink-dark-primary">{urgencyLabel(dict, request.urgency)}</dd>
          {request.destination ? (
            <>
              <dt className={mutedText}>{dict.requests.detail.destination}</dt>
              <dd className="text-ink-primary dark:text-ink-dark-primary">{request.destination.label || t.feed.hasDestination}</dd>
            </>
          ) : null}
          {request.preferredPrice ? (
            <>
              <dt className={mutedText}>{t.feed.budget}</dt>
              <dd>
                <MoneyText amountMinor={request.preferredPrice.amountMinor} currency={request.preferredPrice.currency} />
              </dd>
            </>
          ) : null}
          {request.itemFloat ? (
            <>
              <dt className={mutedText}>{t.feed.itemFloat}</dt>
              <dd>
                <MoneyText amountMinor={request.itemFloat.amountMinor} currency={request.itemFloat.currency} />
              </dd>
            </>
          ) : null}
        </dl>
        <p className={mutedText}>{t.feed.approxArea}</p>

        {mine ? (
          <div className={`${card} flex flex-col gap-sm`} data-testid="feed-my-offer">
            <span className={labelClass}>{t.offerSheet.yourOffer}</span>
            <MoneyText amountMinor={mine.amount.amountMinor} currency={mine.amount.currency} className="text-title-large" />
            <span className={mutedText}>{(t.offers.statuses as Record<string, string>)[mine.status]}</span>
            {mine.status === 'pending' ? (
              <button type="button" disabled={busy} onClick={() => void withdraw(mine)} className={btnDanger}>
                {t.offerSheet.withdraw}
              </button>
            ) : null}
          </div>
        ) : (
          <div className="flex flex-col gap-md">
            <h3 className={sectionTitle}>{t.offerSheet.title}</h3>
            <MoneyField label={t.offerSheet.amount} currency={currency} valueMinor={amount} onChange={setAmount} />
            <label className="flex flex-col gap-xs">
              <span className={labelClass}>{t.offerSheet.message}</span>
              <textarea
                data-testid="offer-message"
                value={message}
                onChange={(e) => setMessage(e.target.value)}
                maxLength={280}
                rows={2}
                className={inputClass}
              />
            </label>
            <button
              type="button"
              data-testid="offer-send"
              disabled={busy || amount === null || amount <= 0}
              onClick={() => void send()}
              className={btnPrimary}
            >
              {t.offerSheet.send}
            </button>
          </div>
        )}
        <Notice text={notice?.text} tone={notice?.tone} />
      </div>
    </Modal>
  );
}
