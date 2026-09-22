'use client';

import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { useQuery } from '@tanstack/react-query';
import { dict } from '@/lib/i18n';
import { directoryRepository, type DirectoryKind } from '@/mocks/repositories';
import type {
  ManagedBusiness,
  ManagedProvider,
  ManagedUser,
  ManagedVehicle,
  ManagedWorker,
} from '@/mocks/types';
import { DataTable, type Column } from '@/components/DataTable';
import { FilterBar } from '@/components/FilterBar';
import { StateBlock } from '@/components/StateBlock';
import { StatusChip } from '@/components/StatusChip';
import { errorText, formatDateTime, isSessionError } from '../_shared';
import { EntityDrawer } from './EntityDrawer';

export type DirectoryTab = 'users' | 'providers' | 'businesses' | 'workers' | 'vehicles';

export type AnyEntity =
  | ManagedUser
  | ManagedProvider
  | ManagedBusiness
  | ManagedWorker
  | ManagedVehicle;

export const TAB_TO_KIND: Record<DirectoryTab, DirectoryKind> = {
  users: 'user',
  providers: 'provider',
  businesses: 'business',
  workers: 'worker',
  vehicles: 'vehicle',
};

const TABS: DirectoryTab[] = ['users', 'providers', 'businesses', 'workers', 'vehicles'];

async function listFor(tab: DirectoryTab, query: string): Promise<AnyEntity[]> {
  const filter = query.trim() === '' ? undefined : { query: query.trim() };
  switch (tab) {
    case 'users':
      return directoryRepository.listUsers(filter);
    case 'providers':
      return directoryRepository.listProviders(filter);
    case 'businesses':
      return directoryRepository.listBusinesses(filter);
    case 'workers':
      return directoryRepository.listWorkers(filter);
    case 'vehicles':
      return directoryRepository.listVehicles(filter);
  }
}

function entityName(e: AnyEntity): string {
  if ('name' in e) return e.name;
  return `${e.make} ${e.model}`;
}

function entityContact(e: AnyEntity): string {
  if ('phone' in e) return e.phone;
  if ('plate' in e) return e.plate;
  if ('registrationNumber' in e) return e.registrationNumber;
  return e.role;
}

function entityTrust(e: AnyEntity): string {
  if (!('trustLevel' in e)) return '—';
  return (dict.directory.trustLevels as Record<string, string>)[e.trustLevel] ?? e.trustLevel;
}

function statusChip(status: AnyEntity['status']) {
  const label = (dict.directory.statuses as Record<string, string>)[status] ?? status;
  return (
    <StatusChip
      label={label}
      tone={status === 'active' ? 'success' : status === 'suspended' ? 'error' : 'neutral'}
    />
  );
}

const columns: Column<AnyEntity>[] = [
  { key: 'name', label: dict.directory.columns.name, render: entityName },
  { key: 'contact', label: dict.directory.columns.phoneEmail, render: entityContact },
  {
    key: 'country',
    label: dict.directory.columns.country,
    render: (e) =>
      'country' in e
        ? ((dict.dashboard.countries as Record<string, string>)[e.country] ?? e.country)
        : '—',
  },
  { key: 'status', label: dict.directory.columns.status, render: (e) => statusChip(e.status) },
  { key: 'trust', label: dict.directory.columns.trustLevel, render: entityTrust },
  {
    key: 'joined',
    label: dict.directory.columns.joined,
    render: (e) => ('joinedAt' in e ? formatDateTime(e.joinedAt) : '—'),
  },
];

export function DirectoryClient() {
  const router = useRouter();
  const [tab, setTab] = useState<DirectoryTab>('users');
  const [search, setSearch] = useState('');
  const [selected, setSelected] = useState<{ kind: DirectoryKind; id: string } | null>(null);

  const query = useQuery({
    queryKey: ['directory', tab, search],
    queryFn: () => listFor(tab, search),
  });

  useEffect(() => {
    if (query.error && isSessionError(query.error)) router.replace('/sign-in');
  }, [query.error, router]);

  return (
    <div className="flex flex-col gap-xl">
      <h1 className="text-headline-medium text-ink-primary dark:text-ink-dark-primary">
        {dict.directory.title}
      </h1>

      <div className="flex flex-wrap gap-sm" role="tablist" aria-label={dict.directory.title}>
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
            {dict.directory.tabs[t]}
          </button>
        ))}
      </div>

      <FilterBar
        searchLabel={dict.common.search}
        searchValue={search}
        onSearchChange={setSearch}
      />

      {query.isPending ? (
        <StateBlock variant="loading" />
      ) : query.isError ? (
        <StateBlock
          variant="error"
          errorMessage={errorText(query.error)}
          retryLabel={dict.common.retry}
          onRetry={() => void query.refetch()}
        />
      ) : (
        <DataTable
          columns={columns}
          rows={query.data}
          keyOf={(e) => e.id}
          emptyTitle={dict.common.emptyGeneric}
          onRowClick={(e) => setSelected({ kind: TAB_TO_KIND[tab], id: e.id })}
        />
      )}

      <EntityDrawer
        selection={selected}
        onClose={() => setSelected(null)}
      />
    </div>
  );
}
