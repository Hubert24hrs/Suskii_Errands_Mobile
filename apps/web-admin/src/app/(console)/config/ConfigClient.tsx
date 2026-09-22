'use client';

// Configuration console: feature flags / country packs / commissions, plus
// the propose → second-admin approval flow. All changes go through
// configRepository.proposeChange / approveChange / rejectChange (sensitive:
// reauth within 5 min via useSensitiveAction). The mock enforces
// proposer ≠ approver server-side; CTAs are hidden client-side only as UX.

import { useEffect, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { dict } from '@/lib/i18n';
import { newIdempotencyKey } from '@/lib/idempotency';
import { configRepository, isAppError } from '@/mocks/repositories';
import type {
  CommissionConfig,
  ConfigChange,
  ConfigChangeStatus,
  CountryPackConfig,
  FeatureFlag,
} from '@/mocks/types';
import { DataTable, type Column } from '@/components/DataTable';
import { Modal } from '@/components/Modal';
import { StateBlock } from '@/components/StateBlock';
import { StatusChip } from '@/components/StatusChip';
import { can, errorText, formatDateTime, isSessionError, useAdminSession } from '../_shared';
import { useSensitiveAction } from './useSensitiveAction';

type Tab = 'flags' | 'packs' | 'commissions';

const TABS: { id: Tab; label: string }[] = [
  { id: 'flags', label: dict.config.tabs.featureFlags },
  { id: 'packs', label: dict.config.tabs.countryPacks },
  { id: 'commissions', label: dict.config.tabs.commissions },
];

const inputClasses =
  'w-full rounded-md border border-outline bg-surface-raised px-md py-sm text-body-large text-ink-primary outline-none transition-colors duration-normal ease-standard focus:border-brand-primary dark:border-outline-dark dark:bg-surface-dark-raised dark:text-ink-dark-primary';

const primaryButton =
  'rounded-md bg-brand-primary px-lg py-sm text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong disabled:opacity-50';
const secondaryButton =
  'rounded-md border border-outline px-lg py-sm text-label-large text-ink-primary transition-colors duration-normal ease-standard hover:bg-surface-muted disabled:opacity-50 dark:border-outline-dark dark:text-ink-dark-primary dark:hover:bg-surface-dark-muted';
const dangerButton =
  'rounded-md border border-error px-lg py-sm text-label-large text-error transition-colors duration-normal ease-standard hover:bg-error/10 disabled:opacity-50 dark:border-error-dark dark:text-error-dark dark:hover:bg-error-dark/20';

function countryName(code: string): string {
  const names = dict.dashboard.countries as Record<string, string>;
  return names[code] ?? code;
}

function changeStatusChip(status: ConfigChangeStatus) {
  const tone =
    status === 'approved' ? 'success' : status === 'rejected' ? 'error' : 'warning';
  return <StatusChip label={dict.config.approval[status]} tone={tone} />;
}

export function ConfigClient() {
  const router = useRouter();
  const queryClient = useQueryClient();
  const sessionQuery = useAdminSession();
  const role = sessionQuery.data?.admin.role;
  const mayRead = role !== undefined && can(role, 'config.read');
  const mayPropose = role !== undefined && can(role, 'config.propose');
  const mayApprove = role !== undefined && can(role, 'config.approve');

  const [tab, setTab] = useState<Tab>('flags');
  const [actionError, setActionError] = useState<string | null>(null);
  const [sameAdminChangeId, setSameAdminChangeId] = useState<string | null>(null);
  const [commissionInputs, setCommissionInputs] = useState<Record<string, string>>({});
  const [rejectTarget, setRejectTarget] = useState<ConfigChange | null>(null);
  const [rejectReason, setRejectReason] = useState('');
  const [busy, setBusy] = useState(false);

  // One key per intent (flag toggle / commission proposal / approve / reject);
  // the key embeds the proposed value so an input change is a fresh intent,
  // and keys are deleted after success.
  const intentKeys = useRef<Record<string, string>>({});
  const keyFor = (name: string) => (intentKeys.current[name] ??= newIdempotencyKey());
  const dropKey = (name: string) => {
    delete intentKeys.current[name];
  };

  const { runSensitive, reauthModal } = useSensitiveAction();

  const configQuery = useQuery({
    queryKey: ['config'],
    queryFn: () => configRepository.getConfig(),
    enabled: mayRead,
    retry: false,
  });
  const changesQuery = useQuery({
    queryKey: ['config', 'changes', 'proposed'],
    queryFn: () => configRepository.listChanges('proposed'),
    enabled: mayRead,
    retry: false,
  });

  useEffect(() => {
    const error = configQuery.error ?? changesQuery.error;
    if (error && isSessionError(error)) router.replace('/sign-in');
  }, [configQuery.error, changesQuery.error, router]);

  const refresh = () => {
    void queryClient.invalidateQueries({ queryKey: ['config'] });
  };

  const run = async (
    purpose: string,
    fn: () => Promise<unknown>,
    options?: { onSuccess?: () => void; sameAdminChangeId?: string },
  ) => {
    setBusy(true);
    setActionError(null);
    if (options?.sameAdminChangeId !== undefined) setSameAdminChangeId(null);
    const result = await runSensitive(purpose, fn);
    if (result.ok) {
      options?.onSuccess?.();
      refresh();
    } else if (result.error != null) {
      if (isAppError(result.error, 'ERR_INVALID_STATE') && options?.sameAdminChangeId) {
        // The mock refuses approver === proposer.
        setSameAdminChangeId(options.sameAdminChangeId);
      } else {
        setActionError(errorText(result.error));
      }
    }
    setBusy(false);
  };

  const proposeFlag = (flag: FeatureFlag) => {
    const next = !flag.enabled;
    const keyName = `flag:${flag.key}:${next}`;
    const summary = `${flag.key}: ${flag.enabled ? dict.config.flags.enabled : dict.config.flags.disabled} → ${next ? dict.config.flags.enabled : dict.config.flags.disabled}`;
    void run('config.propose', () =>
      configRepository.proposeChange(
        {
          target: 'feature_flag',
          targetKey: flag.key,
          summary,
          proposedValue: { enabled: next },
        },
        keyFor(keyName),
      ),
      { onSuccess: () => dropKey(keyName) },
    );
  };

  const proposeCommission = (commission: CommissionConfig) => {
    const raw = (commissionInputs[commission.country] ?? '').trim();
    const bps = Number(raw);
    if (raw === '' || !Number.isSafeInteger(bps) || bps < 0) return;
    const keyName = `commission:${commission.country}:${bps}`;
    void run('config.propose', () =>
      configRepository.proposeChange(
        {
          target: 'commission',
          targetKey: commission.country,
          summary: `${commission.country} commission ${commission.rateBps} → ${bps} bps`,
          proposedValue: { rateBps: bps },
        },
        keyFor(keyName),
      ),
      {
        onSuccess: () => {
          dropKey(keyName);
          setCommissionInputs((prev) => ({ ...prev, [commission.country]: '' }));
        },
      },
    );
  };

  const approve = (change: ConfigChange) => {
    const keyName = `approve:${change.id}`;
    void run(
      'config.approve',
      () => configRepository.approveChange(change.id, keyFor(keyName)),
      { onSuccess: () => dropKey(keyName), sameAdminChangeId: change.id },
    );
  };

  const reject = () => {
    if (!rejectTarget || rejectReason.trim() === '') return;
    const change = rejectTarget;
    const keyName = `reject:${change.id}`;
    void run(
      'config.approve',
      () => configRepository.rejectChange(change.id, rejectReason.trim(), keyFor(keyName)),
      {
        onSuccess: () => {
          dropKey(keyName);
          setRejectTarget(null);
          setRejectReason('');
        },
      },
    );
  };

  if (sessionQuery.isPending) {
    return <StateBlock variant="loading" />;
  }
  if (!mayRead) {
    return (
      <StateBlock
        variant="error"
        errorMessage={dict.errors.ERR_PERMISSION_DENIED}
      />
    );
  }
  if (configQuery.isPending) {
    return <StateBlock variant="loading" />;
  }
  if (configQuery.isError) {
    return (
      <StateBlock
        variant="error"
        errorMessage={errorText(configQuery.error)}
        retryLabel={dict.common.retry}
        onRetry={() => void configQuery.refetch()}
      />
    );
  }

  const config = configQuery.data;
  const pendingChanges = changesQuery.data ?? [];

  const flagColumns: Column<FeatureFlag>[] = [
    {
      key: 'flag',
      label: dict.config.flags.flagLabel,
      render: (flag) => (
        <div className="flex flex-col gap-xxs">
          <span className="text-label-large">{flag.key}</span>
          <span className="text-body-small text-ink-secondary dark:text-ink-dark-secondary">
            {flag.description}
          </span>
        </div>
      ),
    },
    {
      key: 'status',
      label: dict.directory.columns.status,
      render: (flag) => (
        <StatusChip
          label={flag.enabled ? dict.config.flags.enabled : dict.config.flags.disabled}
          tone={flag.enabled ? 'success' : 'neutral'}
        />
      ),
    },
    {
      key: 'countries',
      label: dict.directory.columns.country,
      render: (flag) => (flag.countries.length > 0 ? flag.countries.join(', ') : dict.common.all),
    },
    ...(mayPropose
      ? [
          {
            key: 'actions',
            label: dict.common.actions,
            render: (flag: FeatureFlag) => (
              <button
                type="button"
                disabled={busy}
                onClick={() => proposeFlag(flag)}
                className={secondaryButton}
              >
                {dict.config.flags.toggleCta}
              </button>
            ),
          },
        ]
      : []),
  ];

  const packColumns: Column<CountryPackConfig>[] = [
    { key: 'code', label: dict.config.countryPacks.columns.code, render: (pack) => pack.country },
    {
      key: 'name',
      label: dict.config.countryPacks.columns.name,
      render: (pack) => countryName(pack.country),
    },
    { key: 'currency', label: dict.config.countryPacks.columns.currency },
    {
      key: 'status',
      label: dict.directory.columns.status,
      render: (pack) => (
        <StatusChip
          label={
            pack.live
              ? dict.config.countryPacks.statuses.live
              : dict.config.countryPacks.statuses.beta
          }
          tone={pack.live ? 'success' : 'warning'}
        />
      ),
    },
  ];

  const commissionColumns: Column<CommissionConfig>[] = [
    {
      key: 'country',
      label: dict.directory.columns.country,
      render: (c) => `${countryName(c.country)} (${c.country})`,
    },
    {
      key: 'current',
      label: dict.config.commissions.currentBpsLabel,
      render: (c) => (
        <div className="flex flex-col gap-xxs">
          <span className="text-label-large">{c.rateBps}</span>
          <span className="text-body-small text-ink-secondary dark:text-ink-dark-secondary">
            {formatDateTime(c.effectiveFrom)}
          </span>
        </div>
      ),
    },
    ...(mayPropose
      ? [
          {
            key: 'proposed',
            label: dict.config.commissions.proposedChangeLabel,
            render: (c: CommissionConfig) => (
              <input
                type="number"
                inputMode="numeric"
                min={0}
                value={commissionInputs[c.country] ?? ''}
                onChange={(e) =>
                  setCommissionInputs((prev) => ({ ...prev, [c.country]: e.target.value }))
                }
                className={inputClasses}
              />
            ),
          },
          {
            key: 'actions',
            label: dict.common.actions,
            render: (c: CommissionConfig) => {
              const raw = (commissionInputs[c.country] ?? '').trim();
              const bps = Number(raw);
              const valid = raw !== '' && Number.isSafeInteger(bps) && bps >= 0;
              return (
                <button
                  type="button"
                  disabled={busy || !valid}
                  onClick={() => proposeCommission(c)}
                  className={primaryButton}
                >
                  {dict.config.approval.proposeChangeCta}
                </button>
              );
            },
          },
        ]
      : []),
  ];

  return (
    <div className="flex flex-col gap-xl">
      <h1 className="text-headline-medium text-ink-primary dark:text-ink-dark-primary">
        {dict.config.title}
      </h1>

      <div className="flex flex-wrap gap-sm" role="tablist">
        {TABS.map((t) => (
          <button
            key={t.id}
            type="button"
            role="tab"
            aria-selected={tab === t.id}
            onClick={() => setTab(t.id)}
            className={`rounded-pill px-lg py-sm text-label-large transition-colors duration-normal ease-standard ${
              tab === t.id
                ? 'bg-brand-primary text-brand-on-primary'
                : 'border border-outline text-ink-primary hover:bg-surface-muted dark:border-outline-dark dark:text-ink-dark-primary dark:hover:bg-surface-dark-muted'
            }`}
          >
            {t.label}
          </button>
        ))}
      </div>

      {tab === 'flags' ? (
        <DataTable
          columns={flagColumns}
          rows={config.featureFlags}
          keyOf={(f) => f.key}
          emptyTitle={dict.common.emptyGeneric}
        />
      ) : null}

      {tab === 'packs' ? (
        <DataTable
          columns={packColumns}
          rows={config.countryPacks}
          keyOf={(p) => p.country}
          emptyTitle={dict.common.emptyGeneric}
        />
      ) : null}

      {tab === 'commissions' ? (
        <div className="flex flex-col gap-md">
          <p className="text-body-small text-ink-secondary dark:text-ink-dark-secondary">
            {dict.config.commissions.readOnlyNote}
          </p>
          <DataTable
            columns={commissionColumns}
            rows={config.commissions}
            keyOf={(c) => c.country}
            emptyTitle={dict.common.emptyGeneric}
          />
        </div>
      ) : null}

      <section className="flex flex-col gap-md">
        <h2 className="text-title-large text-ink-primary dark:text-ink-dark-primary">
          {dict.config.approval.pendingApproval}
        </h2>
        <p className="text-body-small text-ink-secondary dark:text-ink-dark-secondary">
          {dict.config.approval.secondAdminNote}
        </p>

        {changesQuery.isPending ? (
          <StateBlock variant="loading" />
        ) : changesQuery.isError ? (
          <StateBlock
            variant="error"
            errorMessage={errorText(changesQuery.error)}
            retryLabel={dict.common.retry}
            onRetry={() => void changesQuery.refetch()}
          />
        ) : pendingChanges.length === 0 ? (
          <StateBlock variant="empty" emptyTitle={dict.common.emptyGeneric} />
        ) : (
          <ul className="flex flex-col gap-md">
            {pendingChanges.map((change) => (
              <li
                key={change.id}
                className="flex flex-col gap-md rounded-lg border border-outline bg-surface-raised p-lg dark:border-outline-dark dark:bg-surface-dark-raised"
              >
                <div className="flex flex-wrap items-center justify-between gap-md">
                  <div className="flex flex-col gap-xxs">
                    <span className="text-body-large text-ink-primary dark:text-ink-dark-primary">
                      {change.summary}
                    </span>
                    <span className="text-body-small text-ink-secondary dark:text-ink-dark-secondary">
                      {change.target}/{change.targetKey}
                    </span>
                  </div>
                  {changeStatusChip(change.status)}
                </div>
                <div className="flex flex-wrap gap-lg text-body-small text-ink-secondary dark:text-ink-dark-secondary">
                  <span>
                    {dict.audit.columns.actor}: {change.proposedByAdminId}
                  </span>
                  <span>
                    {dict.audit.columns.time}: {formatDateTime(change.proposedAt)}
                  </span>
                </div>
                {sameAdminChangeId === change.id ? (
                  <p className="text-body-small text-warning dark:text-warning-dark">
                    {dict.config.approval.sameAdminNote}
                  </p>
                ) : null}
                {mayApprove && change.status === 'proposed' ? (
                  <div className="flex flex-wrap gap-md">
                    <button
                      type="button"
                      disabled={busy}
                      onClick={() => approve(change)}
                      className={primaryButton}
                    >
                      {dict.config.approval.approveChangeCta}
                    </button>
                    <button
                      type="button"
                      disabled={busy}
                      onClick={() => {
                        setRejectTarget(change);
                        setRejectReason('');
                      }}
                      className={dangerButton}
                    >
                      {dict.common.reject}
                    </button>
                  </div>
                ) : null}
              </li>
            ))}
          </ul>
        )}
      </section>

      {actionError !== null ? (
        <p role="alert" className="text-body-medium text-error dark:text-error-dark">
          {actionError}
        </p>
      ) : null}

      <Modal
        open={rejectTarget !== null}
        onClose={() => setRejectTarget(null)}
        title={dict.common.reject}
        closeLabel={dict.common.close}
      >
        <div className="flex flex-col gap-md">
          <div className="flex flex-col gap-xs">
            <label
              htmlFor="reject-reason"
              className="text-label-large text-ink-primary dark:text-ink-dark-primary"
            >
              {dict.common.reason}
            </label>
            <textarea
              id="reject-reason"
              rows={3}
              value={rejectReason}
              onChange={(e) => setRejectReason(e.target.value)}
              placeholder={dict.common.reasonPlaceholder}
              className={inputClasses}
            />
          </div>
          <div className="flex flex-wrap gap-md">
            <button
              type="button"
              disabled={busy || rejectReason.trim() === ''}
              onClick={reject}
              className={dangerButton}
            >
              {dict.common.reject}
            </button>
            <button
              type="button"
              onClick={() => setRejectTarget(null)}
              className={secondaryButton}
            >
              {dict.common.cancel}
            </button>
          </div>
        </div>
      </Modal>

      {reauthModal}
    </div>
  );
}
