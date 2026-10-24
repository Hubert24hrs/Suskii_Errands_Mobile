'use client';

import { useEffect, useRef, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import type { Dictionary } from '@/lib/i18n/en';
import type { Locale } from '@/lib/i18n';
import { providerToolsRepository, walletRepository } from '@/lib/repositories';
import { newIdempotencyKey } from '@/lib/idempotency';
import { formatMoney } from '@/lib/money';
import type { AvailabilitySlot, GoalPeriod, InstantPayoutQuote } from '@/mocks/types';
import { MoneyField } from '@/components/MoneyField';
import { StateBlock } from '@/components/StateBlock';
import {
  Notice,
  ProviderPage,
  btnPrimary,
  btnSecondary,
  card,
  errorText,
  fill,
  inputClass,
  labelClass,
  mutedText,
  pageTitle,
  sectionTitle,
} from '../_shared';

function percent(value: number): string {
  return `${Math.round(value * 100)}%`;
}

function toTime(minutes: number): string {
  const m = Math.min(minutes, 1439);
  return `${String(Math.floor(m / 60)).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`;
}

function fromTime(value: string, end: boolean): number {
  const [h, m] = value.split(':').map(Number);
  const total = h * 60 + m;
  // 23:59 as an end time means "until midnight".
  return end && total === 1439 ? 1440 : total;
}

export function ToolsClient({ locale, dict }: { locale: Locale; dict: Dictionary }) {
  const t = dict.provider.tools;
  return (
    <ProviderPage locale={locale} dict={dict}>
      <h1 className={pageTitle}>{t.title}</h1>
      <Insights dict={dict} />
      <Goal dict={dict} />
      <Heatmap dict={dict} />
      <Availability dict={dict} />
      <InstantPayout dict={dict} />
    </ProviderPage>
  );
}

function Insights({ dict }: { dict: Dictionary }) {
  const t = dict.provider.tools;
  const insights = useQuery({ queryKey: ['provider', 'insights'], queryFn: () => providerToolsRepository.getInsights() });
  return (
    <section className={`${card} flex flex-col gap-md`} data-testid="tools-insights">
      <h2 className={sectionTitle}>{t.insights}</h2>
      {insights.isPending ? (
        <StateBlock variant="loading" />
      ) : insights.isError ? (
        <StateBlock variant="error" errorMessage={errorText(dict, insights.error)} retryLabel={dict.common.retry} onRetry={() => void insights.refetch()} />
      ) : (
        <>
          <p className={mutedText}>{fill(t.period, { days: insights.data.periodDays })}</p>
          <dl className="grid grid-cols-2 gap-md sm:grid-cols-5">
            {(
              [
                [t.acceptance, percent(insights.data.acceptanceRate)],
                [t.completion, percent(insights.data.completionRate)],
                [t.rating, insights.data.avgRating.toFixed(1)],
                [t.fiveStar, percent(insights.data.fiveStarShare)],
                [t.response, fill(t.seconds, { count: insights.data.avgResponseTimeSeconds })],
              ] as const
            ).map(([label, value]) => (
              <div key={label} className="flex flex-col">
                <dt className={mutedText}>{label}</dt>
                <dd className="text-title-large text-ink-primary dark:text-ink-dark-primary">{value}</dd>
              </div>
            ))}
          </dl>
        </>
      )}
    </section>
  );
}

function Goal({ dict }: { dict: Dictionary }) {
  const t = dict.provider.tools;
  const queryClient = useQueryClient();
  const goal = useQuery({ queryKey: ['provider', 'goal'], queryFn: async () => (await providerToolsRepository.getEarningsGoal()) ?? null });
  const summary = useQuery({ queryKey: ['wallet', 'summary'], queryFn: () => walletRepository.getSummary() });
  const currency = goal.data?.target.currency ?? summary.data?.available.currency ?? 'NGN';
  const [amount, setAmount] = useState<number | null>(null);
  const [period, setPeriod] = useState<GoalPeriod>('weekly');
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState<{ text: string; tone: 'success' | 'error' }>();
  const key = useRef<string>(undefined);

  useEffect(() => {
    if (goal.data) {
      setAmount(goal.data.target.amountMinor);
      setPeriod(goal.data.period);
    }
  }, [goal.data]);

  async function save() {
    if (amount === null || amount <= 0) return;
    setBusy(true);
    setNotice(undefined);
    key.current ??= newIdempotencyKey();
    try {
      await providerToolsRepository.setEarningsGoal({ amountMinor: amount, currency }, period, key.current);
      key.current = undefined;
      setNotice({ text: t.goalSaved, tone: 'success' });
      await queryClient.invalidateQueries({ queryKey: ['provider', 'goal'] });
    } catch (error) {
      setNotice({ text: errorText(dict, error), tone: 'error' });
    } finally {
      setBusy(false);
    }
  }

  const data = goal.data;
  const progress = data && data.target.amountMinor > 0 ? Math.min(1, data.progress.amountMinor / data.target.amountMinor) : 0;
  return (
    <section className={`${card} flex flex-col gap-md`} data-testid="tools-goal">
      <h2 className={sectionTitle}>{t.goal}</h2>
      {data ? (
        <div className="flex flex-col gap-xs">
          <p className="text-body-large text-ink-primary dark:text-ink-dark-primary">
            {fill(t.goalProgress, { progress: formatMoney(data.progress), target: formatMoney(data.target) })}
          </p>
          <div className="h-2 w-full overflow-hidden rounded-pill bg-surface-muted dark:bg-surface-dark-muted" aria-hidden>
            <div className="h-full bg-brand-primary dark:bg-brand-secondary" style={{ width: `${Math.round(progress * 100)}%` }} />
          </div>
        </div>
      ) : (
        <p className={mutedText}>{t.goalEmpty}</p>
      )}
      <div className="grid gap-md sm:grid-cols-2">
        <MoneyField label={t.goalAmount} currency={currency} valueMinor={amount} onChange={setAmount} />
        <fieldset className="flex flex-col gap-xs">
          <legend className={labelClass}>{t.goal}</legend>
          <div className="flex gap-md">
            {(['weekly', 'monthly'] as const).map((p) => (
              <label key={p} className="flex items-center gap-xs text-body-medium">
                <input type="radio" name="goal-period" checked={period === p} onChange={() => setPeriod(p)} />
                {t[p]}
              </label>
            ))}
          </div>
        </fieldset>
      </div>
      <div>
        <button type="button" disabled={busy || amount === null || amount <= 0} onClick={() => void save()} className={btnPrimary}>
          {t.goalSave}
        </button>
      </div>
      <Notice text={notice?.text} tone={notice?.tone} />
    </section>
  );
}

function Heatmap({ dict }: { dict: Dictionary }) {
  const t = dict.provider.tools;
  const zones = useQuery({ queryKey: ['provider', 'heatmap'], queryFn: () => providerToolsRepository.getDemandHeatmap() });
  return (
    <section className={`${card} flex flex-col gap-md`} data-testid="tools-heatmap">
      <h2 className={sectionTitle}>{t.heatmap}</h2>
      {zones.isPending ? (
        <StateBlock variant="loading" />
      ) : zones.isError ? (
        <StateBlock variant="error" errorMessage={errorText(dict, zones.error)} retryLabel={dict.common.retry} onRetry={() => void zones.refetch()} />
      ) : zones.data.length === 0 ? (
        <p className={mutedText}>{t.heatmapEmpty}</p>
      ) : (
        <ul className="flex flex-col gap-sm">
          {zones.data.map((zone) => (
            <li key={zone.id} className="flex flex-col gap-xs">
              <div className="flex flex-wrap justify-between gap-sm text-body-medium">
                <span className="text-ink-primary dark:text-ink-dark-primary">{zone.label}</span>
                <span className={mutedText}>{fill(t.heatmapRequests, { count: zone.openRequests })}</span>
              </div>
              <div className="h-2 w-full overflow-hidden rounded-pill bg-surface-muted dark:bg-surface-dark-muted" aria-hidden>
                <div className="h-full bg-brand-primary dark:bg-brand-secondary" style={{ width: `${Math.round(zone.intensity * 100)}%` }} />
              </div>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

function Availability({ dict }: { dict: Dictionary }) {
  const t = dict.provider.tools;
  const queryClient = useQueryClient();
  const saved = useQuery({ queryKey: ['provider', 'availability'], queryFn: () => providerToolsRepository.getAvailability() });
  const [slots, setSlots] = useState<AvailabilitySlot[] | undefined>(undefined);
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState<{ text: string; tone: 'success' | 'error' }>();
  const key = useRef<{ forSlots: string; key: string }>(undefined);

  useEffect(() => {
    if (saved.data && slots === undefined) setSlots(saved.data);
  }, [saved.data, slots]);

  const update = (index: number, patch: Partial<AvailabilitySlot>) =>
    setSlots((current) => current?.map((slot, i) => (i === index ? { ...slot, ...patch } : slot)));

  async function save() {
    if (!slots) return;
    setBusy(true);
    setNotice(undefined);
    // A retry of the same week replays; an edited week is a new intent.
    const forSlots = JSON.stringify(slots);
    if (key.current?.forSlots !== forSlots) key.current = { forSlots, key: newIdempotencyKey() };
    try {
      const result = await providerToolsRepository.setAvailability(slots, key.current.key);
      key.current = undefined;
      setSlots(result);
      setNotice({ text: t.availabilitySaved, tone: 'success' });
      await queryClient.invalidateQueries({ queryKey: ['provider', 'availability'] });
    } catch (error) {
      setNotice({ text: errorText(dict, error), tone: 'error' });
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className={`${card} flex flex-col gap-md`} data-testid="tools-availability">
      <h2 className={sectionTitle}>{t.availability}</h2>
      {slots === undefined ? (
        saved.isError ? (
          <StateBlock variant="error" errorMessage={errorText(dict, saved.error)} retryLabel={dict.common.retry} onRetry={() => void saved.refetch()} />
        ) : (
          <StateBlock variant="loading" />
        )
      ) : (
        <>
          {slots.length === 0 ? <p className={mutedText}>{t.availabilityEmpty}</p> : null}
          <ul className="flex flex-col gap-sm">
            {slots.map((slot, index) => (
              <li key={index} className="flex flex-wrap items-end gap-sm">
                <label className="flex flex-col gap-xs">
                  <span className={labelClass}>{t.day}</span>
                  <select
                    value={slot.dayOfWeek}
                    onChange={(e) => update(index, { dayOfWeek: Number(e.target.value) })}
                    className={inputClass}
                  >
                    {t.days.map((name, i) => (
                      <option key={name} value={i + 1}>
                        {name}
                      </option>
                    ))}
                  </select>
                </label>
                <label className="flex flex-col gap-xs">
                  <span className={labelClass}>{t.from}</span>
                  <input
                    type="time"
                    value={toTime(slot.startMinutes)}
                    onChange={(e) => update(index, { startMinutes: fromTime(e.target.value, false) })}
                    className={inputClass}
                  />
                </label>
                <label className="flex flex-col gap-xs">
                  <span className={labelClass}>{t.to}</span>
                  <input
                    type="time"
                    value={toTime(slot.endMinutes)}
                    onChange={(e) => update(index, { endMinutes: fromTime(e.target.value, true) })}
                    className={inputClass}
                  />
                </label>
                <button
                  type="button"
                  onClick={() => setSlots((current) => current?.filter((_, i) => i !== index))}
                  className={btnSecondary}
                >
                  {t.removeSlot}
                </button>
              </li>
            ))}
          </ul>
          <div className="flex flex-wrap gap-sm">
            <button
              type="button"
              onClick={() => setSlots((current) => [...(current ?? []), { dayOfWeek: 1, startMinutes: 9 * 60, endMinutes: 17 * 60 }])}
              className={btnSecondary}
            >
              {t.addSlot}
            </button>
            <button type="button" disabled={busy} onClick={() => void save()} className={btnPrimary}>
              {t.availabilitySave}
            </button>
          </div>
        </>
      )}
      <Notice text={notice?.text} tone={notice?.tone} />
    </section>
  );
}

/** Also opened from the dashboard header, in a modal that carries the title (`bare`). */
export function InstantPayout({ dict, bare = false }: { dict: Dictionary; bare?: boolean }) {
  const t = dict.provider.tools;
  const queryClient = useQueryClient();
  const summary = useQuery({ queryKey: ['wallet', 'summary'], queryFn: () => walletRepository.getSummary() });
  const currency = summary.data?.available.currency ?? 'NGN';
  const [amount, setAmount] = useState<number | null>(null);
  const [quote, setQuote] = useState<InstantPayoutQuote>();
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState<{ text: string; tone: 'success' | 'error' }>();
  const key = useRef<string>(undefined);

  async function getQuote() {
    if (amount === null || amount <= 0) return;
    setBusy(true);
    setNotice(undefined);
    try {
      setQuote(await providerToolsRepository.quoteInstantPayout({ amountMinor: amount, currency }));
    } catch (error) {
      setNotice({ text: errorText(dict, error), tone: 'error' });
    } finally {
      setBusy(false);
    }
  }

  async function request() {
    if (amount === null) return;
    setBusy(true);
    setNotice(undefined);
    key.current ??= newIdempotencyKey();
    try {
      await providerToolsRepository.requestInstantPayout({ amountMinor: amount, currency }, key.current);
      key.current = undefined;
      setQuote(undefined);
      setNotice({ text: t.instantPayoutDone, tone: 'success' });
      await queryClient.invalidateQueries({ queryKey: ['wallet'] });
    } catch (error) {
      setNotice({ text: errorText(dict, error), tone: 'error' });
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className={`${bare ? '' : card} flex flex-col gap-md`} data-testid="tools-instant-payout">
      {bare ? null : <h2 className={sectionTitle}>{t.instantPayout}</h2>}
      <p className={mutedText}>{t.instantPayoutBody}</p>
      <MoneyField
        label={t.instantPayoutAmount}
        currency={currency}
        valueMinor={amount}
        onChange={(value) => {
          setAmount(value);
          setQuote(undefined);
        }}
      />
      {quote ? (
        <p className="text-body-medium text-ink-primary dark:text-ink-dark-primary">
          {fill(t.instantPayoutQuote, {
            fee: formatMoney(quote.fee),
            net: formatMoney(quote.net),
            minutes: quote.arrivesWithinMinutes,
          })}
        </p>
      ) : null}
      <div className="flex flex-wrap gap-sm">
        <button type="button" data-testid="instant-payout-quote" disabled={busy || amount === null || amount <= 0} onClick={() => void getQuote()} className={btnSecondary}>
          {t.instantPayoutQuoteCta}
        </button>
        {quote ? (
          <button type="button" disabled={busy} onClick={() => void request()} className={btnPrimary}>
            {t.instantPayoutCta}
          </button>
        ) : null}
      </div>
      <Notice text={notice?.text} tone={notice?.tone} />
    </section>
  );
}
