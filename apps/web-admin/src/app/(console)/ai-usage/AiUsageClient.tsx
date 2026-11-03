'use client';

// Ask Suskii usage and cost (20261103120200). What it is used for and what it costs, for finance
// and super admins; who uses it, for support too; and the controls: one person's limits, credits
// and suspension (support and super admin), and the platform's budget, free allowance and switch
// (super admin). Spend is an estimate from list prices, in integer micro-dollars.

import { useMemo, useRef, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { dict } from '@/lib/i18n';
import { newIdempotencyKey } from '@/lib/idempotency';
import { aiUsageRepository } from '@/lib/repositories';
import type { AiUserUsage } from '@/mocks/types';
import { DataTable, type Column } from '@/components/DataTable';
import { KpiCard } from '@/components/KpiCard';
import { Modal } from '@/components/Modal';
import { StateBlock } from '@/components/StateBlock';
import { StatusChip } from '@/components/StatusChip';
import { adminRoles, can, errorText, formatDateTime, useAdminSession } from '../_shared';
import { useSensitiveAction } from '../config/useSensitiveAction';
import {
  Field,
  downloadCsv,
  inputClass,
  microsFromUsd,
  panelClass,
  primaryButton,
  secondaryButton,
  usd,
  usdInput,
} from '../_form';

const t = dict.aiUsage;
const isoDay = (d: Date) => d.toISOString().slice(0, 10);
const fill = (text: string, values: Record<string, string | number>) =>
  Object.entries(values).reduce((s, [k, v]) => s.replace(`{${k}}`, String(v)), text);

type PersonAction = { kind: 'limits' | 'credits' | 'suspend' | 'lift'; person: AiUserUsage };

export function AiUsageClient() {
  const queryClient = useQueryClient();
  const sessionQuery = useAdminSession();
  const role = adminRoles(sessionQuery.data);
  const maySeeSpend = role !== undefined && can(role, 'aiUsage.read');
  const maySeePeople = role !== undefined && can(role, 'aiUsage.people');
  const mayManage = role !== undefined && can(role, 'aiUsage.manage');
  const mayControl = role !== undefined && can(role, 'aiUsage.controls');
  const { runSensitive, reauthModal } = useSensitiveAction();

  const today = useMemo(() => new Date(), []);
  const [from, setFrom] = useState(isoDay(new Date(today.getTime() - 29 * 86_400_000)));
  const [to, setTo] = useState(isoDay(today));
  const [sort, setSort] = useState<'cost' | 'near_limit'>('near_limit');
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const summary = useQuery({
    queryKey: ['aiUsage', 'summary', from, to],
    queryFn: () => aiUsageRepository.getSummary(from, to),
    enabled: maySeeSpend,
  });
  const people = useQuery({
    queryKey: ['aiUsage', 'people', from, to, sort],
    queryFn: () => aiUsageRepository.listUsers(from, to, sort),
    enabled: maySeePeople,
  });

  // Control forms, prefilled from the summary once it arrives.
  const [budgetDaily, setBudgetDaily] = useState<string | null>(null);
  const [budgetMonthly, setBudgetMonthly] = useState<string | null>(null);
  const [tierDaily, setTierDaily] = useState<string | null>(null);
  const [tierMonthly, setTierMonthly] = useState<string | null>(null);
  const [controlReason, setControlReason] = useState('');

  const [action, setAction] = useState<PersonAction | null>(null);
  const [daily, setDaily] = useState('');
  const [monthly, setMonthly] = useState('');
  const [until, setUntil] = useState('');
  const [credits, setCredits] = useState('5');
  const [reason, setReason] = useState('');
  const creditKey = useRef<string | null>(null);

  const refresh = () => void queryClient.invalidateQueries({ queryKey: ['aiUsage'] });

  const run = async (fn: () => Promise<unknown>, after?: () => void) => {
    setBusy(true);
    setError(null);
    setNotice(null);
    const result = await runSensitive('aiUsage', fn);
    setBusy(false);
    if (result.ok) {
      after?.();
      setNotice(t.done);
      refresh();
    } else if (result.error) {
      setError(errorText(result.error));
    }
  };

  const openAction = (kind: PersonAction['kind'], person: AiUserUsage) => {
    setDaily(String(person.dailyLimit));
    setMonthly(String(person.monthlyLimit));
    setUntil('');
    setCredits('5');
    setReason('');
    setError(null);
    creditKey.current = null;
    setAction({ kind, person });
  };

  const submitAction = () => {
    if (!action) return;
    const { kind, person } = action;
    const close = () => setAction(null);
    const untilDate = until ? new Date(until) : null;
    if (kind === 'limits') {
      void run(() => aiUsageRepository.setQuota(person.userId, Number(daily), Number(monthly), untilDate, reason.trim()), close);
    } else if (kind === 'credits') {
      creditKey.current ??= newIdempotencyKey();
      const key = creditKey.current;
      void run(() => aiUsageRepository.grantCredits(key, person.userId, Number(credits), reason.trim()), close);
    } else if (kind === 'suspend') {
      if (!untilDate) return;
      void run(() => aiUsageRepository.setSuspension(person.userId, untilDate, reason.trim()), close);
    } else {
      void run(() => aiUsageRepository.setSuspension(person.userId, null, reason.trim()), close);
    }
  };

  const clearLimits = () => {
    if (!action) return;
    const { person } = action;
    void run(() => aiUsageRepository.setQuota(person.userId, null, null, null, reason.trim()), () => setAction(null));
  };

  if (sessionQuery.isPending) return <StateBlock variant="loading" />;
  if (!maySeePeople) return <StateBlock variant="error" errorMessage={dict.errors.ERR_PERMISSION_DENIED} />;

  const s = summary.data;
  const freeTier = s?.tiers.free;
  const peopleColumns: Column<AiUserUsage>[] = [
    {
      key: 'person',
      label: t.columns.person,
      render: (p) => (
        <div className="flex flex-col">
          <span>{p.displayName || p.userId.slice(0, 8)}</span>
          <span className="text-body-small text-ink-secondary dark:text-ink-dark-secondary">{p.countryCode}</span>
        </div>
      ),
    },
    { key: 'requests', label: t.columns.requests, render: (p) => String(p.requests) },
    { key: 'today', label: t.columns.today, render: (p) => `${p.usedToday} / ${p.dailyLimit}` },
    { key: 'month', label: t.columns.month, render: (p) => `${p.usedThisMonth} / ${p.monthlyLimit}` },
    { key: 'credits', label: t.columns.credits, render: (p) => String(p.credits) },
    { key: 'spend', label: t.columns.spend, render: (p) => usd(p.costMicros) },
    {
      key: 'status',
      label: t.columns.status,
      render: (p) =>
        p.suspendedUntil ? (
          <StatusChip label={fill(t.suspendedUntil, { when: formatDateTime(p.suspendedUntil) })} tone="error" />
        ) : p.overrideExpiresAt ? (
          <StatusChip label={fill(t.overrideUntil, { when: formatDateTime(p.overrideExpiresAt) })} tone="warning" />
        ) : p.usedToday >= p.dailyLimit ? (
          <StatusChip label={`${p.usedToday} / ${p.dailyLimit}`} tone="warning" />
        ) : null,
    },
    {
      key: 'actions',
      label: dict.common.actions,
      render: (p) =>
        mayManage ? (
          <div className="flex flex-wrap gap-xs">
            <button type="button" className={secondaryButton} onClick={() => openAction('limits', p)}>
              {t.setLimits}
            </button>
            <button type="button" className={secondaryButton} onClick={() => openAction('credits', p)}>
              {t.grant}
            </button>
            {p.suspendedUntil ? (
              <button type="button" className={secondaryButton} onClick={() => openAction('lift', p)}>
                {t.lift}
              </button>
            ) : (
              <button type="button" className={secondaryButton} onClick={() => openAction('suspend', p)}>
                {t.suspend}
              </button>
            )}
          </div>
        ) : null,
    },
  ];

  const actionTitle = action
    ? fill(
        action.kind === 'limits'
          ? t.editor.limitsTitle
          : action.kind === 'credits'
            ? t.editor.creditsTitle
            : action.kind === 'suspend'
              ? t.editor.suspendTitle
              : t.editor.liftTitle,
        { name: action.person.displayName || action.person.userId.slice(0, 8) },
      )
    : '';
  const actionReady =
    reason.trim().length >= 3 &&
    (action?.kind !== 'limits' || (/^\d+$/.test(daily) && /^\d+$/.test(monthly) && Number(daily) <= Number(monthly))) &&
    (action?.kind !== 'credits' || (/^\d+$/.test(credits) && Number(credits) >= 1 && Number(credits) <= 1000)) &&
    (action?.kind !== 'suspend' || until !== '');

  return (
    <div className="flex flex-col gap-xl">
      <div className="flex flex-col gap-xs">
        <h1 className="text-headline-medium text-ink-primary dark:text-ink-dark-primary">{t.title}</h1>
        <p className="text-body-medium text-ink-secondary dark:text-ink-dark-secondary">{t.subtitle}</p>
      </div>

      <div className="flex flex-wrap items-end gap-md">
        <Field label={t.from}>
          <input type="date" className={inputClass} value={from} max={to} onChange={(e) => setFrom(e.target.value)} />
        </Field>
        <Field label={t.to}>
          <input type="date" className={inputClass} value={to} min={from} onChange={(e) => setTo(e.target.value)} />
        </Field>
      </div>

      {notice ? (
        <p role="status" className="text-body-medium text-success dark:text-success-dark">
          {notice}
        </p>
      ) : null}
      {error && !action ? (
        <p role="alert" className="text-body-small text-error dark:text-error-dark">
          {error}
        </p>
      ) : null}

      {maySeeSpend ? (
        summary.isPending ? (
          <StateBlock variant="loading" />
        ) : summary.isError ? (
          <StateBlock variant="error" errorMessage={errorText(summary.error)} retryLabel={dict.common.retry} onRetry={() => void summary.refetch()} />
        ) : s ? (
          <>
            <div className="grid gap-md sm:grid-cols-2 lg:grid-cols-4" data-testid="ai-usage-kpis">
              <KpiCard label={t.kpis.requests} value={String(s.totals.requests)} />
              <KpiCard label={t.kpis.spend} value={usd(s.totals.costMicros)} />
              <KpiCard label={t.kpis.users} value={String(s.totals.users)} />
              <KpiCard label={t.kpis.perUser} value={usd(s.totals.avgCostPerUserMicros)} />
              <KpiCard label={t.kpis.tokensIn} value={s.totals.tokensIn.toLocaleString('en-GB')} />
              <KpiCard label={t.kpis.tokensOut} value={(s.totals.tokensOut + s.totals.tokensThought).toLocaleString('en-GB')} />
              <KpiCard label={t.kpis.failed} value={String(s.totals.failed)} tone={s.totals.failed > 0 ? 'warning' : 'neutral'} />
            </div>
            {s.pricingVerifiedAt ? (
              <p className="text-body-small text-ink-secondary dark:text-ink-dark-secondary">{fill(t.pricing, { date: s.pricingVerifiedAt })}</p>
            ) : null}

            <div className="grid gap-md lg:grid-cols-3">
              <section className={panelClass} data-testid="ai-budget">
                <h2 className="text-title-medium text-ink-primary dark:text-ink-dark-primary">{t.budget.title}</h2>
                <p className="text-body-medium">
                  {t.budget.today}: {fill(t.budget.spent, { spent: usd(s.budget.spentTodayMicros), limit: usd(s.budget.dailyMicros) })}
                </p>
                <p className="text-body-medium">
                  {t.budget.month}: {fill(t.budget.spent, { spent: usd(s.budget.spentThisMonthMicros), limit: usd(s.budget.monthlyMicros) })}
                </p>
                {s.budget.dayExceeded || s.budget.monthExceeded ? (
                  <p role="status" className="text-body-medium text-error dark:text-error-dark">
                    {fill(t.budget.exceeded, {
                      when: formatDateTime(s.budget.monthExceeded ? s.budget.monthResetsAt : s.budget.dayResetsAt),
                    })}
                  </p>
                ) : null}
                {mayControl ? (
                  <>
                    <Field label={t.budget.daily}>
                      <input className={inputClass} inputMode="decimal" value={budgetDaily ?? usdInput(s.budget.dailyMicros)} onChange={(e) => setBudgetDaily(e.target.value)} />
                    </Field>
                    <Field label={t.budget.monthly}>
                      <input className={inputClass} inputMode="decimal" value={budgetMonthly ?? usdInput(s.budget.monthlyMicros)} onChange={(e) => setBudgetMonthly(e.target.value)} />
                    </Field>
                    <button
                      type="button"
                      className={primaryButton}
                      disabled={busy || controlReason.trim().length < 3}
                      onClick={() => {
                        const d = microsFromUsd(budgetDaily ?? usdInput(s.budget.dailyMicros));
                        const m = microsFromUsd(budgetMonthly ?? usdInput(s.budget.monthlyMicros));
                        if (d === null || m === null || d > m) {
                          setError(dict.errors.ERR_INVALID_ARGUMENT);
                          return;
                        }
                        void run(() => aiUsageRepository.setBudget(d, m, controlReason.trim()), () => {
                          setBudgetDaily(null);
                          setBudgetMonthly(null);
                        });
                      }}
                    >
                      {t.budget.save}
                    </button>
                  </>
                ) : null}
              </section>

              <section className={panelClass} data-testid="ai-switch">
                <h2 className="text-title-medium text-ink-primary dark:text-ink-dark-primary">{t.switch.title}</h2>
                <StatusChip label={s.enabled ? t.switch.on : t.switch.off} tone={s.enabled ? 'success' : 'error'} />
                {mayControl ? (
                  <button
                    type="button"
                    className={s.enabled ? secondaryButton : primaryButton}
                    disabled={busy || controlReason.trim().length < 3}
                    onClick={() => void run(() => aiUsageRepository.setEnabled(!s.enabled, controlReason.trim()))}
                  >
                    {s.enabled ? t.switch.turnOff : t.switch.turnOn}
                  </button>
                ) : null}
              </section>

              <section className={panelClass} data-testid="ai-allowance">
                <h2 className="text-title-medium text-ink-primary dark:text-ink-dark-primary">{t.allowance.title}</h2>
                {freeTier ? (
                  mayControl ? (
                    <>
                      <Field label={t.allowance.daily}>
                        <input className={inputClass} inputMode="numeric" value={tierDaily ?? String(freeTier.daily)} onChange={(e) => setTierDaily(e.target.value)} />
                      </Field>
                      <Field label={t.allowance.monthly}>
                        <input className={inputClass} inputMode="numeric" value={tierMonthly ?? String(freeTier.monthly)} onChange={(e) => setTierMonthly(e.target.value)} />
                      </Field>
                      <button
                        type="button"
                        className={primaryButton}
                        disabled={busy || controlReason.trim().length < 3}
                        onClick={() => {
                          const d = tierDaily ?? String(freeTier.daily);
                          const m = tierMonthly ?? String(freeTier.monthly);
                          if (!/^\d+$/.test(d) || !/^\d+$/.test(m) || Number(d) > Number(m)) {
                            setError(dict.errors.ERR_INVALID_ARGUMENT);
                            return;
                          }
                          void run(() => aiUsageRepository.setTier('free', Number(d), Number(m), controlReason.trim()), () => {
                            setTierDaily(null);
                            setTierMonthly(null);
                          });
                        }}
                      >
                        {t.allowance.save}
                      </button>
                    </>
                  ) : (
                    <p className="text-body-medium">
                      {t.allowance.daily}: {freeTier.daily} · {t.allowance.monthly}: {freeTier.monthly}
                    </p>
                  )
                ) : null}
              </section>
            </div>
            {mayControl ? (
              <Field label={t.editor.reason}>
                <input className={inputClass} maxLength={300} value={controlReason} onChange={(e) => setControlReason(e.target.value)} />
              </Field>
            ) : null}

            <section className="flex flex-col gap-sm">
              <div className="flex items-center justify-between gap-md">
                <h2 className="text-title-large text-ink-primary dark:text-ink-dark-primary">{t.byDay}</h2>
                <button
                  type="button"
                  className={secondaryButton}
                  onClick={() =>
                    downloadCsv(`ai-usage-${from}-${to}.csv`, ['day', 'messages', 'failed', 'tokens_in', 'tokens_out', 'cost_micros', 'people'],
                      s.byDay.map((d) => [d.day, d.requests, d.failed, d.tokensIn, d.tokensOut, d.costMicros, d.users]))
                  }
                >
                  {t.exportCsv}
                </button>
              </div>
              <DataTable
                columns={[
                  { key: 'day', label: t.columns.day, render: (d) => d.day },
                  { key: 'requests', label: t.columns.requests, render: (d) => String(d.requests) },
                  { key: 'failed', label: t.columns.failed, render: (d) => String(d.failed) },
                  { key: 'tokensIn', label: t.columns.tokensIn, render: (d) => d.tokensIn.toLocaleString('en-GB') },
                  { key: 'tokensOut', label: t.columns.tokensOut, render: (d) => d.tokensOut.toLocaleString('en-GB') },
                  { key: 'spend', label: t.columns.spend, render: (d) => usd(d.costMicros) },
                  { key: 'users', label: t.columns.users, render: (d) => String(d.users) },
                ]}
                rows={s.byDay}
                keyOf={(d) => d.day}
                emptyTitle={dict.common.emptyGeneric}
              />
            </section>

            <section className="flex flex-col gap-sm">
              <h2 className="text-title-large text-ink-primary dark:text-ink-dark-primary">{t.byModel}</h2>
              <DataTable
                columns={[
                  { key: 'model', label: t.columns.model, render: (m) => m.modelId },
                  { key: 'location', label: t.columns.location, render: (m) => m.location ?? '—' },
                  { key: 'requests', label: t.columns.requests, render: (m) => String(m.requests) },
                  { key: 'tokensIn', label: t.columns.tokensIn, render: (m) => m.tokensIn.toLocaleString('en-GB') },
                  { key: 'tokensOut', label: t.columns.tokensOut, render: (m) => m.tokensOut.toLocaleString('en-GB') },
                  { key: 'spend', label: t.columns.spend, render: (m) => usd(m.costMicros) },
                ]}
                rows={s.byModel}
                keyOf={(m) => `${m.modelId}@${m.location ?? ''}`}
                emptyTitle={dict.common.emptyGeneric}
              />
            </section>
          </>
        ) : null
      ) : null}

      <section className="flex flex-col gap-sm">
        <div className="flex flex-wrap items-center justify-between gap-md">
          <h2 className="text-title-large text-ink-primary dark:text-ink-dark-primary">{t.people}</h2>
          <div className="flex gap-xs">
            <button type="button" className={secondaryButton} aria-pressed={sort === 'near_limit'} onClick={() => setSort('near_limit')}>
              {t.sortNear}
            </button>
            <button type="button" className={secondaryButton} aria-pressed={sort === 'cost'} onClick={() => setSort('cost')}>
              {t.sortCost}
            </button>
            <button
              type="button"
              className={secondaryButton}
              disabled={!people.data}
              onClick={() =>
                downloadCsv(`ai-usage-people-${from}-${to}.csv`,
                  ['user_id', 'name', 'country', 'messages', 'failed', 'tokens', 'cost_micros', 'used_today', 'daily_limit', 'used_this_month', 'monthly_limit', 'credits'],
                  (people.data ?? []).map((p) => [p.userId, p.displayName, p.countryCode, p.requests, p.failed, p.tokens, p.costMicros, p.usedToday, p.dailyLimit, p.usedThisMonth, p.monthlyLimit, p.credits]))
              }
            >
              {t.exportCsv}
            </button>
          </div>
        </div>
        {people.isPending ? (
          <StateBlock variant="loading" />
        ) : people.isError ? (
          <StateBlock variant="error" errorMessage={errorText(people.error)} retryLabel={dict.common.retry} onRetry={() => void people.refetch()} />
        ) : (
          <DataTable columns={peopleColumns} rows={people.data} keyOf={(p) => p.userId} emptyTitle={dict.common.emptyGeneric} />
        )}
      </section>

      <Modal open={action !== null} onClose={() => setAction(null)} title={actionTitle} closeLabel={t.editor.cancel}>
        {action ? (
          <div className="flex flex-col gap-md">
            {action.kind === 'limits' ? (
              <>
                <Field label={t.editor.dailyLimit}>
                  <input className={inputClass} inputMode="numeric" value={daily} onChange={(e) => setDaily(e.target.value)} />
                </Field>
                <Field label={t.editor.monthlyLimit}>
                  <input className={inputClass} inputMode="numeric" value={monthly} onChange={(e) => setMonthly(e.target.value)} />
                </Field>
                <Field label={t.editor.until}>
                  <input type="datetime-local" className={inputClass} value={until} onChange={(e) => setUntil(e.target.value)} />
                </Field>
              </>
            ) : null}
            {action.kind === 'credits' ? (
              <Field label={t.editor.credits}>
                <input className={inputClass} inputMode="numeric" value={credits} onChange={(e) => setCredits(e.target.value)} />
              </Field>
            ) : null}
            {action.kind === 'suspend' ? (
              <Field label={t.editor.suspendUntil}>
                <input type="datetime-local" className={inputClass} value={until} onChange={(e) => setUntil(e.target.value)} />
              </Field>
            ) : null}
            <Field label={t.editor.reason}>
              <input className={inputClass} maxLength={300} value={reason} onChange={(e) => setReason(e.target.value)} />
            </Field>
            {error ? (
              <p role="alert" className="text-body-small text-error dark:text-error-dark">
                {error}
              </p>
            ) : null}
            <div className="flex flex-wrap justify-end gap-sm">
              {action.kind === 'limits' && action.person.overrideExpiresAt !== undefined ? (
                <button type="button" className={secondaryButton} disabled={busy || reason.trim().length < 3} onClick={clearLimits}>
                  {t.editor.clear}
                </button>
              ) : null}
              <button type="button" className={secondaryButton} onClick={() => setAction(null)}>
                {t.editor.cancel}
              </button>
              <button type="button" className={primaryButton} disabled={!actionReady || busy} onClick={submitAction}>
                {t.editor.save}
              </button>
            </div>
          </div>
        ) : null}
      </Modal>

      {reauthModal}
    </div>
  );
}
