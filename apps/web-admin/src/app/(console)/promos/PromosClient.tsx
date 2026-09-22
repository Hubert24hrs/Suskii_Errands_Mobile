'use client';

import { useEffect, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { dict } from '@/lib/i18n';
import { newIdempotencyKey } from '@/lib/idempotency';
import { promoRepository } from '@/mocks/repositories';
import type { PromoCampaign } from '@/mocks/types';
import { DataTable, type Column } from '@/components/DataTable';
import { MoneyText } from '@/components/MoneyText';
import { StateBlock } from '@/components/StateBlock';
import { StatusChip } from '@/components/StatusChip';
import { can, errorText, formatDateTime, isSessionError, useAdminSession } from '../_shared';
import { CreatePromoModal } from './CreatePromoModal';

function promoStatusChip(status: PromoCampaign['status']) {
  const label = (dict.promos.statuses as Record<string, string>)[status] ?? status;
  const tone =
    status === 'active'
      ? 'success'
      : status === 'paused'
        ? 'warning'
        : status === 'expired'
          ? 'error'
          : 'neutral';
  return <StatusChip label={label} tone={tone} />;
}

const actionButtonClass =
  'rounded-md border border-outline px-md py-xs text-label-large text-ink-primary transition-colors duration-normal ease-standard hover:bg-surface-muted disabled:opacity-50 dark:border-outline-dark dark:text-ink-dark-primary dark:hover:bg-surface-dark-muted';

export function PromosClient() {
  const router = useRouter();
  const queryClient = useQueryClient();
  const sessionQuery = useAdminSession();
  const role = sessionQuery.data?.admin.role;
  const mayRead = role !== undefined && can(role, 'promos.read');
  const mayManage = role !== undefined && can(role, 'promos.manage');

  const [createOpen, setCreateOpen] = useState(false);
  const [actionError, setActionError] = useState<string | null>(null);
  const [busyId, setBusyId] = useState<string | null>(null);

  // One idempotency key per (status change, promo) intent; deleted on success.
  const intentKeys = useRef<Record<string, string>>({});
  const keyFor = (name: string) => (intentKeys.current[name] ??= newIdempotencyKey());

  const promosQuery = useQuery({
    queryKey: ['promos', 'list'],
    queryFn: () => promoRepository.listPromos(),
    enabled: mayRead,
  });

  useEffect(() => {
    if (promosQuery.error && isSessionError(promosQuery.error)) router.replace('/sign-in');
  }, [promosQuery.error, router]);

  const setStatus = async (promo: PromoCampaign, status: 'active' | 'paused') => {
    const keyName = `status:${promo.id}:${status}`;
    setBusyId(promo.id);
    setActionError(null);
    try {
      await promoRepository.setPromoStatus(promo.id, status, keyFor(keyName));
      delete intentKeys.current[keyName];
      void queryClient.invalidateQueries({ queryKey: ['promos'] });
    } catch (e) {
      if (isSessionError(e)) {
        router.replace('/sign-in');
      } else {
        setActionError(errorText(e));
      }
    } finally {
      setBusyId(null);
    }
  };

  const columns: Column<PromoCampaign>[] = [
    { key: 'code', label: dict.promos.columns.code, render: (p) => p.code },
    {
      key: 'percentOff',
      label: dict.promos.columns.percentOff,
      render: (p) => `${p.discountPercent}%`,
    },
    {
      key: 'maxDiscount',
      label: dict.promos.columns.maxDiscount,
      render: (p) =>
        p.maxDiscount ? (
          <MoneyText
            amountMinor={p.maxDiscount.amountMinor}
            currency={p.maxDiscount.currency}
          />
        ) : (
          '—'
        ),
    },
    {
      key: 'redemptions',
      label: dict.promos.columns.redemptions,
      render: (p) => `${p.redemptions} / ${p.maxRedemptions}`,
    },
    {
      key: 'expires',
      label: dict.promos.columns.expires,
      render: (p) => formatDateTime(p.endsAt),
    },
    {
      key: 'status',
      label: dict.promos.columns.status,
      render: (p) => promoStatusChip(p.status),
    },
    {
      key: 'actions',
      label: dict.common.actions,
      render: (p) => {
        if (!mayManage || p.status === 'expired') return null;
        // setPromoStatus: draft → active, active ⇄ paused.
        const target = p.status === 'active' ? 'paused' : 'active';
        return (
          <button
            type="button"
            disabled={busyId !== null}
            onClick={() => void setStatus(p, target)}
            className={actionButtonClass}
          >
            {target === 'paused' ? dict.promos.pauseCta : dict.promos.resumeCta}
          </button>
        );
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
          {dict.promos.title}
        </h1>
        {mayManage ? (
          <button
            type="button"
            onClick={() => setCreateOpen(true)}
            className="rounded-md bg-brand-primary px-xl py-sm text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong"
          >
            {dict.promos.editor.createTitle}
          </button>
        ) : null}
      </div>

      {actionError ? (
        <p role="alert" className="text-body-small text-error dark:text-error-dark">
          {actionError}
        </p>
      ) : null}

      {promosQuery.isPending ? (
        <StateBlock variant="loading" />
      ) : promosQuery.isError ? (
        <StateBlock
          variant="error"
          errorMessage={errorText(promosQuery.error)}
          retryLabel={dict.common.retry}
          onRetry={() => void promosQuery.refetch()}
        />
      ) : (
        <DataTable
          columns={columns}
          rows={promosQuery.data}
          keyOf={(p) => p.id}
          emptyTitle={dict.common.emptyGeneric}
        />
      )}

      <CreatePromoModal open={createOpen} onClose={() => setCreateOpen(false)} />
    </div>
  );
}
