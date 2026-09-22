'use client';

import { useEffect, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { dict } from '@/lib/i18n';
import { newIdempotencyKey } from '@/lib/idempotency';
import { referralRepository } from '@/mocks/repositories';
import type {
  ReferralAttribution,
  ReferralCampaign,
  ReferralFlaggedCase,
} from '@/mocks/types';
import { DataTable, type Column } from '@/components/DataTable';
import { MoneyText } from '@/components/MoneyText';
import { StateBlock } from '@/components/StateBlock';
import { can, errorText, formatDateTime, isSessionError, useAdminSession } from '../_shared';
import { campaignStatusChip, countryLabel, flagStatusChip } from './_shared';
import { CreateCampaignModal } from './CreateCampaignModal';

type Tab = keyof typeof dict.referrals.tabs;
const TABS = Object.keys(dict.referrals.tabs) as Tab[];

const actionButtonClass =
  'rounded-md border border-outline px-md py-xs text-label-large text-ink-primary transition-colors duration-normal ease-standard hover:bg-surface-muted disabled:opacity-50 dark:border-outline-dark dark:text-ink-dark-primary dark:hover:bg-surface-dark-muted';
const dangerButtonClass =
  'rounded-md border border-error px-md py-xs text-label-large text-error transition-colors duration-normal ease-standard hover:bg-error/10 disabled:opacity-50 dark:border-error-dark dark:text-error-dark dark:hover:bg-error-dark/20';

export function ReferralsClient() {
  const router = useRouter();
  const queryClient = useQueryClient();
  const sessionQuery = useAdminSession();
  const role = sessionQuery.data?.admin.role;
  const mayRead = role !== undefined && can(role, 'referrals.read');
  const mayManage = role !== undefined && can(role, 'referrals.manage');

  const [tab, setTab] = useState<Tab>('attributions');
  const [createOpen, setCreateOpen] = useState(false);
  const [actionError, setActionError] = useState<string | null>(null);

  // One idempotency key per (action, target) intent; deleted after success.
  const intentKeys = useRef<Record<string, string>>({});
  const keyFor = (name: string) => (intentKeys.current[name] ??= newIdempotencyKey());

  const attributionsQuery = useQuery({
    queryKey: ['referrals', 'attributions'],
    queryFn: () => referralRepository.listAttributions(),
    enabled: mayRead && tab === 'attributions',
  });
  const flaggedQuery = useQuery({
    queryKey: ['referrals', 'flagged'],
    queryFn: () => referralRepository.listFlaggedCases(),
    enabled: mayRead && tab === 'flagged',
  });
  const campaignsQuery = useQuery({
    queryKey: ['referrals', 'campaigns'],
    queryFn: () => referralRepository.listCampaigns(),
    enabled: mayRead && tab === 'campaigns',
  });

  const activeQuery =
    tab === 'attributions' ? attributionsQuery : tab === 'flagged' ? flaggedQuery : campaignsQuery;

  useEffect(() => {
    if (activeQuery.error && isSessionError(activeQuery.error)) router.replace('/sign-in');
  }, [activeQuery.error, router]);

  const refresh = () => void queryClient.invalidateQueries({ queryKey: ['referrals'] });

  const [busyKey, setBusyKey] = useState<string | null>(null);
  const runAction = async (keyName: string, fn: (key: string) => Promise<unknown>) => {
    setBusyKey(keyName);
    setActionError(null);
    try {
      await fn(keyFor(keyName));
      delete intentKeys.current[keyName];
      refresh();
    } catch (e) {
      if (isSessionError(e)) {
        router.replace('/sign-in');
      } else {
        // ERR_ALREADY_REVIEWED lands here and renders its dedicated dict copy.
        setActionError(errorText(e));
      }
    } finally {
      setBusyKey(null);
    }
  };

  const attributionColumns: Column<ReferralAttribution>[] = [
    { key: 'id', label: dict.referrals.columns.id, render: (a) => a.id },
    {
      key: 'referrer',
      label: dict.referrals.columns.referrer,
      render: (a) => a.referrerName,
    },
    { key: 'referee', label: dict.referrals.columns.referee, render: (a) => a.refereeName },
    {
      key: 'reward',
      label: dict.referrals.columns.reward,
      render: (a) => (
        <MoneyText
          amountMinor={a.commissionEarned.amountMinor}
          currency={a.commissionEarned.currency}
        />
      ),
    },
    {
      key: 'created',
      label: dict.referrals.columns.created,
      render: (a) => formatDateTime(a.attributedAt),
    },
  ];

  const flaggedColumns: Column<ReferralFlaggedCase>[] = [
    { key: 'id', label: dict.referrals.columns.id, render: (f) => f.id },
    {
      key: 'flaggedReason',
      label: dict.referrals.columns.flaggedReason,
      render: (f) => (
        <span>
          <span className="block">
            {(dict.referrals.flagReasons as Record<string, string>)[f.reason] ?? f.reason}
          </span>
          <span className="block text-body-small text-ink-secondary dark:text-ink-dark-secondary">
            {f.signals.join(', ')}
          </span>
        </span>
      ),
    },
    {
      key: 'status',
      label: dict.referrals.columns.status,
      render: (f) => flagStatusChip(f.status),
    },
    {
      key: 'created',
      label: dict.referrals.columns.created,
      render: (f) => formatDateTime(f.flaggedAt),
    },
    {
      key: 'actions',
      label: dict.common.actions,
      render: (f) => {
        if (!mayManage || f.status !== 'open') return null;
        return (
          <div className="flex flex-wrap gap-sm" onClick={(e) => e.stopPropagation()}>
            <button
              type="button"
              disabled={busyKey !== null}
              onClick={() =>
                void runAction(`flag-clear:${f.id}`, (key) =>
                  referralRepository.reviewFlag(f.id, 'dismiss', key),
                )
              }
              className={actionButtonClass}
            >
              {dict.referrals.flagReview.clearCta}
            </button>
            <button
              type="button"
              disabled={busyKey !== null}
              onClick={() =>
                void runAction(`flag-abuse:${f.id}`, (key) =>
                  referralRepository.reviewFlag(f.id, 'confirm_abuse', key),
                )
              }
              className={dangerButtonClass}
            >
              {dict.referrals.flagReview.confirmAbuseCta}
            </button>
          </div>
        );
      },
    },
  ];

  const campaignColumns: Column<ReferralCampaign>[] = [
    { key: 'name', label: dict.referrals.campaign.nameLabel, render: (c) => c.name },
    {
      key: 'country',
      label: dict.directory.columns.country,
      render: (c) => countryLabel(c.country),
    },
    {
      key: 'referrerReward',
      label: `${dict.referrals.columns.referrer} — ${dict.referrals.campaign.rewardAmountLabel}`,
      render: (c) => (
        <MoneyText
          amountMinor={c.referrerReward.amountMinor}
          currency={c.referrerReward.currency}
        />
      ),
    },
    {
      key: 'refereeReward',
      label: `${dict.referrals.columns.referee} — ${dict.referrals.campaign.rewardAmountLabel}`,
      render: (c) => (
        <MoneyText
          amountMinor={c.refereeReward.amountMinor}
          currency={c.refereeReward.currency}
        />
      ),
    },
    {
      key: 'status',
      label: dict.referrals.columns.status,
      render: (c) => campaignStatusChip(c.status),
    },
    {
      key: 'startsAt',
      label: dict.common.fromDate,
      render: (c) => formatDateTime(c.startsAt),
    },
    {
      key: 'actions',
      label: dict.common.actions,
      render: (c) => {
        if (!mayManage) return null;
        if (c.status === 'active') {
          return (
            <div onClick={(e) => e.stopPropagation()}>
              <button
                type="button"
                disabled={busyKey !== null}
                onClick={() =>
                  void runAction(`campaign-pause:${c.id}`, (key) =>
                    referralRepository.pauseCampaign(c.id, key),
                  )
                }
                className={actionButtonClass}
              >
                {dict.referrals.campaign.pauseCta}
              </button>
            </div>
          );
        }
        if (c.status === 'paused') {
          return (
            <div onClick={(e) => e.stopPropagation()}>
              <button
                type="button"
                disabled={busyKey !== null}
                onClick={() =>
                  void runAction(`campaign-resume:${c.id}`, (key) =>
                    referralRepository.resumeCampaign(c.id, key),
                  )
                }
                className={actionButtonClass}
              >
                {dict.referrals.campaign.resumeCta}
              </button>
            </div>
          );
        }
        // Ended campaigns are read-only.
        return null;
      },
    },
  ];

  if (sessionQuery.isPending) {
    return <StateBlock variant="loading" />;
  }
  if (!mayRead) {
    // Defense in depth: the nav hides this module, and the repo re-checks.
    return <StateBlock variant="error" errorMessage={dict.errors.ERR_PERMISSION_DENIED} />;
  }

  return (
    <div className="flex flex-col gap-xl">
      <div className="flex flex-wrap items-center justify-between gap-md">
        <h1 className="text-headline-medium text-ink-primary dark:text-ink-dark-primary">
          {dict.referrals.title}
        </h1>
        {mayManage && tab === 'campaigns' ? (
          <button
            type="button"
            onClick={() => setCreateOpen(true)}
            className="rounded-md bg-brand-primary px-xl py-sm text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong"
          >
            {dict.referrals.campaign.createCta}
          </button>
        ) : null}
      </div>

      <div className="flex flex-wrap gap-sm" role="tablist" aria-label={dict.referrals.title}>
        {TABS.map((t) => (
          <button
            key={t}
            type="button"
            role="tab"
            aria-selected={tab === t}
            onClick={() => {
              setTab(t);
              setActionError(null);
            }}
            className={`rounded-pill px-lg py-sm text-label-large transition-colors duration-normal ease-standard ${
              tab === t
                ? 'bg-brand-primary text-brand-on-primary'
                : 'border border-outline text-ink-primary hover:bg-surface-muted dark:border-outline-dark dark:text-ink-dark-primary dark:hover:bg-surface-dark-muted'
            }`}
          >
            {dict.referrals.tabs[t]}
          </button>
        ))}
      </div>

      {actionError ? (
        <p role="alert" className="text-body-small text-error dark:text-error-dark">
          {actionError}
        </p>
      ) : null}

      {activeQuery.isPending ? (
        <StateBlock variant="loading" />
      ) : activeQuery.isError ? (
        <StateBlock
          variant="error"
          errorMessage={errorText(activeQuery.error)}
          retryLabel={dict.common.retry}
          onRetry={() => void activeQuery.refetch()}
        />
      ) : tab === 'attributions' ? (
        <DataTable
          columns={attributionColumns}
          rows={attributionsQuery.data ?? []}
          keyOf={(a) => a.id}
          emptyTitle={dict.common.emptyGeneric}
        />
      ) : tab === 'flagged' ? (
        <DataTable
          columns={flaggedColumns}
          rows={flaggedQuery.data ?? []}
          keyOf={(f) => f.id}
          emptyTitle={dict.common.emptyGeneric}
        />
      ) : (
        <DataTable
          columns={campaignColumns}
          rows={campaignsQuery.data ?? []}
          keyOf={(c) => c.id}
          emptyTitle={dict.common.emptyGeneric}
        />
      )}

      <CreateCampaignModal open={createOpen} onClose={() => setCreateOpen(false)} />
    </div>
  );
}
