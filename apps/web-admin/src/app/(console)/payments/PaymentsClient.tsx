'use client';

import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { useQuery } from '@tanstack/react-query';
import { dict } from '@/lib/i18n';
import { paymentsRepository } from '@/mocks/repositories';
import type { PaymentAdminView } from '@/mocks/types';
import { DataTable, type Column } from '@/components/DataTable';
import { MoneyText } from '@/components/MoneyText';
import { StateBlock } from '@/components/StateBlock';
import { can, errorText, isSessionError, useAdminSession } from '../_shared';
import { ageDays, kindLabel, paymentStatusChip, TAB_KIND, type PaymentTab } from './_shared';
import { PaymentDrawer } from './PaymentDrawer';

const TABS = Object.keys(TAB_KIND) as PaymentTab[];

export function PaymentsClient() {
  const router = useRouter();
  const sessionQuery = useAdminSession();
  const role = sessionQuery.data?.admin.role;
  const mayRead = role !== undefined && can(role, 'payments.read');

  const [tab, setTab] = useState<PaymentTab>('holds');
  const [selectedId, setSelectedId] = useState<string | null>(null);

  const paymentsQuery = useQuery({
    queryKey: ['payments', tab],
    queryFn: () => paymentsRepository.listPayments({ kind: TAB_KIND[tab] }),
    enabled: mayRead,
  });

  useEffect(() => {
    if (paymentsQuery.error && isSessionError(paymentsQuery.error)) {
      router.replace('/sign-in');
    }
  }, [paymentsQuery.error, router]);

  const columns: Column<PaymentAdminView>[] = [
    { key: 'id', label: dict.payments.columns.id, render: (p) => p.id },
    {
      key: 'user',
      label: dict.payments.columns.user,
      render: (p) => p.counterpartyName,
    },
    { key: 'kind', label: dict.payments.columns.kind, render: (p) => kindLabel(p.kind) },
    {
      key: 'amount',
      label: dict.payments.columns.amount,
      render: (p) => (
        <MoneyText amountMinor={p.quote.gross.amountMinor} currency={p.quote.gross.currency} />
      ),
    },
    {
      key: 'status',
      label: dict.payments.columns.status,
      render: (p) => paymentStatusChip(p.status),
    },
    { key: 'age', label: dict.payments.columns.age, render: (p) => ageDays(p.createdAt) },
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
      <h1 className="text-headline-medium text-ink-primary dark:text-ink-dark-primary">
        {dict.payments.title}
      </h1>

      <div className="flex flex-wrap gap-sm" role="tablist" aria-label={dict.payments.title}>
        {TABS.map((t) => (
          <button
            key={t}
            type="button"
            role="tab"
            aria-selected={tab === t}
            onClick={() => setTab(t)}
            className={`rounded-pill px-lg py-sm text-label-large transition-colors duration-normal ease-standard ${
              tab === t
                ? 'bg-brand-primary text-brand-on-primary'
                : 'border border-outline text-ink-primary hover:bg-surface-muted dark:border-outline-dark dark:text-ink-dark-primary dark:hover:bg-surface-dark-muted'
            }`}
          >
            {dict.payments.tabs[t]}
          </button>
        ))}
      </div>

      {paymentsQuery.isPending ? (
        <StateBlock variant="loading" />
      ) : paymentsQuery.isError ? (
        <StateBlock
          variant="error"
          errorMessage={errorText(paymentsQuery.error)}
          retryLabel={dict.common.retry}
          onRetry={() => void paymentsQuery.refetch()}
        />
      ) : (
        <DataTable
          columns={columns}
          rows={paymentsQuery.data}
          keyOf={(p) => p.id}
          emptyTitle={dict.common.emptyGeneric}
          onRowClick={(p) => setSelectedId(p.id)}
        />
      )}

      <PaymentDrawer paymentId={selectedId} onClose={() => setSelectedId(null)} />
    </div>
  );
}
