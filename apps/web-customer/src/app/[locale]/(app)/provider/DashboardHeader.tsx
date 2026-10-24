'use client';

// The account header of the provider dashboard, laid out after the sportsbook
// account panels the owner pointed at (2026-10-24): who you are and your tier,
// progress towards the earnings goal, the balance hidden until asked for, and
// the two ways money leaves. Mirrors apps/mobile/lib/features/provider/
// provider_dashboard_header.dart.

import Link from 'next/link';
import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import type { Dictionary } from '@/lib/i18n/en';
import type { Locale } from '@/lib/i18n';
import { SERVED_COUNTRIES } from '@/lib/deviceCountry';
import { formatMoney } from '@/lib/money';
import { providerToolsRepository, userRepository, walletRepository } from '@/lib/repositories';
import type { AppUser, GoalPeriod, TrustLevel } from '@/mocks/types';
import { Modal } from '@/components/Modal';
import { WithdrawalModal } from '../wallet/WithdrawalModal';
import { InstantPayout } from './tools/ToolsClient';
import { card, fill, labelClass, mutedText } from './_shared';

const DIAL_CODES: Record<(typeof SERVED_COUNTRIES)[number], string> = {
  NG: '234',
  KE: '254',
  GH: '233',
  ZA: '27',
  UG: '256',
};

/** `80*******5`: the first two national digits and the last. Email accounts keep the first letter and the domain. */
export function maskAccount(user: Pick<AppUser, 'phoneE164' | 'email'>): string {
  if (user.phoneE164) {
    let digits = user.phoneE164.replace(/\D/g, '');
    const code = Object.values(DIAL_CODES).find((c) => digits.startsWith(c) && digits.length - c.length >= 6);
    if (code) digits = digits.slice(code.length);
    if (digits.length < 4) return '*'.repeat(digits.length);
    return `${digits.slice(0, 2)}${'*'.repeat(digits.length - 3)}${digits.slice(-1)}`;
  }
  if (user.email?.includes('@')) {
    const at = user.email.indexOf('@');
    return `${user.email.slice(0, at > 0 ? 1 : 0)}***${user.email.slice(at)}`;
  }
  return '';
}

/** When the goal starts again, as `my_earnings_goal` counts it: weeks on Monday, months on the first. */
export function goalPeriodEnd(period: GoalPeriod, now: Date): Date {
  if (period === 'weekly') {
    const weekday = now.getDay() === 0 ? 7 : now.getDay();
    return new Date(now.getFullYear(), now.getMonth(), now.getDate() + 8 - weekday);
  }
  return new Date(now.getFullYear(), now.getMonth() + 1, 1);
}

const TIERS: Record<TrustLevel, string> = { new: 'I', verified: 'II', trusted: 'III', elite: 'IV' };

const successFilled =
  'flex-1 rounded-md bg-success px-lg py-sm text-center text-label-large text-white transition-opacity duration-normal ease-standard hover:opacity-90 disabled:opacity-50 dark:bg-success-dark dark:text-surface-dark-background';
const successOutlined =
  'flex-1 rounded-md border-2 border-success px-lg py-sm text-center text-label-large text-success transition-colors duration-normal ease-standard hover:bg-success/10 disabled:opacity-50 dark:border-success-dark dark:text-success-dark';

export function DashboardHeader({ locale, dict }: { locale: Locale; dict: Dictionary }) {
  const t = dict.provider.dashboard;
  const queryClient = useQueryClient();
  // Hidden on every visit: a balance on the first screen is read over a shoulder more often than it is needed.
  const [revealed, setRevealed] = useState(false);
  const [withdrawOpen, setWithdrawOpen] = useState(false);
  const [payoutOpen, setPayoutOpen] = useState(false);

  const profile = useQuery({ queryKey: ['user', 'me'], queryFn: () => userRepository.getProfile() });
  const wallet = useQuery({ queryKey: ['wallet', 'summary'], queryFn: () => walletRepository.getSummary() });
  const goal = useQuery({
    queryKey: ['provider', 'goal'],
    queryFn: async () => (await providerToolsRepository.getEarningsGoal()) ?? null,
  });

  const user = profile.data;
  const summary = wallet.data;
  const total = summary
    ? { amountMinor: summary.available.amountMinor + summary.pending.amountMinor, currency: summary.available.currency }
    : undefined;
  const currency = total?.currency ?? 'NGN';
  const g = goal.data;
  const ratio = g && g.target.amountMinor > 0 ? Math.min(1, Math.max(0, g.progress.amountMinor / g.target.amountMinor)) : 0;
  const account = user ? maskAccount(user) || user.displayName : '';

  return (
    <section className={`${card} flex flex-col gap-md`} data-testid="provider-dashboard">
      <div className="flex items-center gap-md">
        <Link
          href={`/${locale}/settings`}
          aria-label={t.account}
          className="flex min-w-0 flex-1 items-center gap-md rounded-md"
          data-testid="dashboard-account"
        >
          <span className="relative inline-flex h-12 w-12 shrink-0 items-center justify-center rounded-pill bg-brand-gradient p-[2px]">
            <span className="flex h-full w-full items-center justify-center rounded-pill bg-surface-high text-title-medium text-ink-primary dark:bg-surface-dark-high dark:text-ink-dark-primary">
              {(user?.displayName.trim()[0] ?? '').toUpperCase()}
            </span>
            <span
              className="absolute -bottom-1 -right-1 rounded-pill border-2 border-surface-raised bg-warning px-[5px] text-label-small font-extrabold text-white dark:border-surface-dark-raised dark:bg-warning-dark dark:text-surface-dark-background"
              data-testid="dashboard-tier-badge"
            >
              {TIERS[user?.trustLevel ?? 'new']}
            </span>
          </span>
          <span className="truncate text-title-medium text-ink-primary dark:text-ink-dark-primary" data-testid="dashboard-account-label">
            {account}
          </span>
          <span aria-hidden className="text-title-medium text-ink-secondary dark:text-ink-dark-secondary">
            ›
          </span>
        </Link>
        <Link
          href={`/${locale}/settings`}
          aria-label={t.settings}
          title={t.settings}
          className="rounded-md p-sm text-ink-secondary hover:text-ink-primary dark:text-ink-dark-secondary dark:hover:text-ink-dark-primary"
          data-testid="dashboard-settings"
        >
          <svg aria-hidden viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" strokeWidth="1.8">
            <circle cx="12" cy="12" r="3" />
            <path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z" />
          </svg>
        </Link>
      </div>

      {user ? (
        <p className={labelClass} data-testid="dashboard-tier">
          {fill(t.trustTier, { tier: TIERS[user.trustLevel], level: dict.offers.trustLevels[user.trustLevel] })}
        </p>
      ) : null}
      <div className="flex flex-col gap-xs">
        <div
          role="progressbar"
          aria-valuemin={0}
          aria-valuemax={100}
          aria-valuenow={Math.round(ratio * 100)}
          className="h-[6px] overflow-hidden rounded-pill bg-surface-high dark:bg-surface-dark-high"
        >
          <div className="h-full rounded-pill bg-warning dark:bg-warning-dark" style={{ width: `${ratio * 100}%` }} />
        </div>
        <div className="flex flex-wrap items-center justify-between gap-sm">
          {g ? (
            <>
              <span className={mutedText}>
                {fill(t.goalProgress, { progress: formatMoney(g.progress), target: formatMoney(g.target) })}
              </span>
              <span className={mutedText} data-testid="dashboard-goal-resets">
                {fill(t.goalResets, {
                  date: goalPeriodEnd(g.period, new Date()).toLocaleDateString(locale === 'pcm' ? 'en-NG' : 'en-GB', {
                    day: 'numeric',
                    month: 'short',
                  }),
                })}
              </span>
            </>
          ) : goal.isSuccess ? (
            <Link href={`/${locale}/provider/tools`} className="text-label-large text-brand-primary hover:underline dark:text-brand-secondary">
              {t.noGoal}
            </Link>
          ) : null}
        </div>
      </div>

      <div className="flex flex-col gap-xs">
        <span className={mutedText}>{t.totalBalance}</span>
        <div className="flex items-center gap-sm">
          <span className="truncate text-headline-medium text-ink-primary dark:text-ink-dark-primary" data-testid="dashboard-balance">
            {revealed && total ? formatMoney(total) : `${currency} *****`}
          </span>
          <button
            type="button"
            onClick={() => setRevealed((r) => !r)}
            aria-label={revealed ? t.hideBalance : t.showBalance}
            aria-pressed={revealed}
            title={revealed ? t.hideBalance : t.showBalance}
            className="rounded-md p-xs text-ink-secondary hover:text-ink-primary dark:text-ink-dark-secondary dark:hover:text-ink-dark-primary"
            data-testid="dashboard-toggle-balance"
          >
            <svg aria-hidden viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" strokeWidth="1.8">
              <path d="M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7S2 12 2 12z" />
              <circle cx="12" cy="12" r="3" />
              {revealed ? <path d="M3 3l18 18" /> : null}
            </svg>
          </button>
        </div>
        {revealed && summary ? (
          <span className={mutedText}>
            {fill(t.balanceSplit, { available: formatMoney(summary.available), pending: formatMoney(summary.pending) })}
          </span>
        ) : null}
      </div>

      <div className="flex gap-md">
        <button
          type="button"
          disabled={!summary}
          onClick={() => setWithdrawOpen(true)}
          className={successFilled}
          data-testid="dashboard-withdraw"
        >
          {t.withdraw}
        </button>
        <button type="button" onClick={() => setPayoutOpen(true)} className={successOutlined} data-testid="dashboard-instant-payout">
          {t.instantPayout}
        </button>
      </div>

      {summary ? (
        <WithdrawalModal
          open={withdrawOpen}
          onClose={() => setWithdrawOpen(false)}
          dict={dict}
          currency={summary.available.currency}
          title={dict.wallet.withdrawal.title}
          confirmCta={dict.wallet.withdrawal.confirmCta}
          doneNote={dict.wallet.withdrawal.doneNote}
          onSubmit={(amountMinor, idempotencyKey) =>
            walletRepository.requestWithdrawal({ amountMinor, currency: summary.available.currency }, idempotencyKey)
          }
          onSuccess={() => void queryClient.invalidateQueries({ queryKey: ['wallet'] })}
        />
      ) : null}
      <Modal open={payoutOpen} onClose={() => setPayoutOpen(false)} title={t.instantPayout} closeLabel={dict.common.close}>
        {payoutOpen ? <InstantPayout dict={dict} bare /> : null}
      </Modal>
    </section>
  );
}
