'use client';

import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { dict } from '@/lib/i18n';
import { newIdempotencyKey } from '@/lib/idempotency';
import { directoryRepository, type DirectoryKind } from '@/mocks/repositories';
import { Drawer } from '@/components/Drawer';
import { Modal } from '@/components/Modal';
import { StateBlock } from '@/components/StateBlock';
import { StatusChip } from '@/components/StatusChip';
import {
  can,
  errorText,
  formatDateTime,
  useAdminSession,
} from '../_shared';
import type { AnyEntity } from './DirectoryClient';

async function getEntity(kind: DirectoryKind, id: string): Promise<AnyEntity> {
  switch (kind) {
    case 'user':
      return directoryRepository.getUser(id);
    case 'provider':
      return directoryRepository.getProvider(id);
    case 'business':
      return directoryRepository.getBusiness(id);
    case 'worker':
      return directoryRepository.getWorker(id);
    case 'vehicle':
      return directoryRepository.getVehicle(id);
  }
}

function DetailRow({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex flex-wrap justify-between gap-md py-sm">
      <span className="text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
        {label}
      </span>
      <span className="text-body-medium text-ink-primary dark:text-ink-dark-primary">
        {value}
      </span>
    </div>
  );
}

function EntityDetails({ entity }: { entity: AnyEntity }) {
  return (
    <div className="divide-y divide-outline dark:divide-outline-dark">
      <DetailRow
        label={dict.directory.columns.status}
        value={(dict.directory.statuses as Record<string, string>)[entity.status] ?? entity.status}
      />
      <DetailRow
        label={dict.directory.detail.verificationStatus}
        value={
          (dict.directory.verificationStatuses as Record<string, string>)[
            entity.verificationStatus
          ] ?? entity.verificationStatus
        }
      />
      {'trustLevel' in entity ? (
        <DetailRow
          label={dict.directory.detail.trustLevel}
          value={
            (dict.directory.trustLevels as Record<string, string>)[entity.trustLevel] ??
            entity.trustLevel
          }
        />
      ) : null}
      {'country' in entity ? (
        <DetailRow
          label={dict.directory.detail.country}
          value={
            (dict.dashboard.countries as Record<string, string>)[entity.country] ??
            entity.country
          }
        />
      ) : null}
      {'jobsCount' in entity ? (
        <DetailRow label={dict.directory.detail.jobsCompleted} value={String(entity.jobsCount)} />
      ) : null}
      {'completedJobs' in entity ? (
        <DetailRow
          label={dict.directory.detail.jobsCompleted}
          value={String(entity.completedJobs)}
        />
      ) : null}
      {'rating' in entity ? (
        <DetailRow label={dict.directory.detail.rating} value={`★ ${entity.rating}`} />
      ) : null}
      {'joinedAt' in entity ? (
        <DetailRow label={dict.directory.detail.joined} value={formatDateTime(entity.joinedAt)} />
      ) : null}
      {entity.suspension ? (
        <DetailRow
          label={dict.common.reason}
          value={`${entity.suspension.reason} (${formatDateTime(entity.suspension.at)})`}
        />
      ) : null}
    </div>
  );
}

export function EntityDrawer({
  selection,
  onClose,
}: {
  selection: { kind: DirectoryKind; id: string } | null;
  onClose: () => void;
}) {
  const queryClient = useQueryClient();
  const sessionQuery = useAdminSession();
  const role = sessionQuery.data?.admin.role;
  const maySuspend = role !== undefined && can(role, 'directory.suspend');

  const entityQuery = useQuery({
    queryKey: ['directory', 'detail', selection?.kind, selection?.id],
    queryFn: () => getEntity(selection!.kind, selection!.id),
    enabled: selection !== null,
  });

  const [suspendOpen, setSuspendOpen] = useState(false);
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState(false);
  const [actionError, setActionError] = useState<string | null>(null);
  // One key per suspend/unsuspend intent; regenerated on success or when the
  // reason input changes.
  const [intent, setIntent] = useState<{ key: string; fingerprint: string } | null>(null);

  const keyFor = (fingerprint: string) => {
    const current =
      intent && intent.fingerprint === fingerprint
        ? intent
        : { key: newIdempotencyKey(), fingerprint };
    setIntent(current);
    return current.key;
  };

  const refresh = () => {
    void queryClient.invalidateQueries({ queryKey: ['directory'] });
  };

  const suspend = async () => {
    if (!selection || reason.trim() === '') return;
    setBusy(true);
    setActionError(null);
    try {
      await directoryRepository.suspendEntity(
        selection.kind,
        selection.id,
        reason.trim(),
        keyFor(`suspend:${reason.trim()}`),
      );
      setIntent(null);
      setSuspendOpen(false);
      setReason('');
      refresh();
    } catch (e) {
      setActionError(errorText(e));
    } finally {
      setBusy(false);
    }
  };

  const unsuspend = async () => {
    if (!selection) return;
    setBusy(true);
    setActionError(null);
    try {
      await directoryRepository.unsuspendEntity(
        selection.kind,
        selection.id,
        keyFor('unsuspend'),
      );
      setIntent(null);
      refresh();
    } catch (e) {
      setActionError(errorText(e));
    } finally {
      setBusy(false);
    }
  };

  const entity = entityQuery.data;
  const title = entity ? ('name' in entity ? entity.name : `${entity.make} ${entity.model}`) : '';

  return (
    <Drawer
      open={selection !== null}
      onClose={onClose}
      title={title}
      closeLabel={dict.common.close}
    >
      {entityQuery.isPending ? (
        <StateBlock variant="loading" />
      ) : entityQuery.isError ? (
        <StateBlock
          variant="error"
          errorMessage={errorText(entityQuery.error)}
          retryLabel={dict.common.retry}
          onRetry={() => void entityQuery.refetch()}
        />
      ) : entity ? (
        <div className="flex flex-col gap-lg">
          <div className="flex items-center gap-md">
            <StatusChip
              label={
                (dict.directory.statuses as Record<string, string>)[entity.status] ??
                entity.status
              }
              tone={entity.status === 'active' ? 'success' : 'error'}
            />
          </div>

          <EntityDetails entity={entity} />

          {actionError ? (
            <p role="alert" className="text-body-small text-error dark:text-error-dark">
              {actionError}
            </p>
          ) : null}

          {maySuspend ? (
            entity.status === 'suspended' ? (
              <button
                type="button"
                disabled={busy}
                onClick={() => void unsuspend()}
                className="w-fit rounded-md bg-brand-primary px-xl py-sm text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong disabled:opacity-50"
              >
                {dict.directory.unsuspendCta}
              </button>
            ) : (
              <button
                type="button"
                disabled={busy}
                onClick={() => {
                  setActionError(null);
                  setSuspendOpen(true);
                }}
                className="w-fit rounded-md border border-error px-xl py-sm text-label-large text-error transition-colors duration-normal ease-standard hover:bg-error/10 disabled:opacity-50 dark:border-error-dark dark:text-error-dark dark:hover:bg-error-dark/20"
              >
                {dict.directory.suspendCta}
              </button>
            )
          ) : null}
        </div>
      ) : null}

      <Modal
        open={suspendOpen}
        onClose={() => setSuspendOpen(false)}
        title={dict.directory.suspendCta}
        closeLabel={dict.common.close}
      >
        <div className="flex flex-col gap-lg">
          <div className="flex flex-col gap-xs">
            <label
              htmlFor="suspend-reason"
              className="text-label-large text-ink-primary dark:text-ink-dark-primary"
            >
              {dict.directory.suspendReasonLabel}
            </label>
            <textarea
              id="suspend-reason"
              rows={3}
              value={reason}
              onChange={(e) => setReason(e.target.value)}
              placeholder={dict.common.reasonPlaceholder}
              className="rounded-md border border-outline bg-surface-raised px-md py-sm text-body-large text-ink-primary outline-none transition-colors duration-normal ease-standard focus:border-brand-primary placeholder:text-ink-secondary dark:border-outline-dark dark:bg-surface-dark-raised dark:text-ink-dark-primary dark:placeholder:text-ink-dark-secondary"
            />
          </div>
          {actionError ? (
            <p role="alert" className="text-body-small text-error dark:text-error-dark">
              {actionError}
            </p>
          ) : null}
          <div className="flex gap-md">
            <button
              type="button"
              disabled={busy || reason.trim() === ''}
              onClick={() => void suspend()}
              className="rounded-md bg-error px-xl py-sm text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:opacity-90 disabled:opacity-50 dark:bg-error-dark"
            >
              {dict.common.confirm}
            </button>
            <button
              type="button"
              onClick={() => setSuspendOpen(false)}
              className="rounded-md border border-outline px-lg py-sm text-label-large text-ink-primary transition-colors duration-normal ease-standard hover:bg-surface-muted dark:border-outline-dark dark:text-ink-dark-primary dark:hover:bg-surface-dark-muted"
            >
              {dict.common.cancel}
            </button>
          </div>
        </div>
      </Modal>
    </Drawer>
  );
}
