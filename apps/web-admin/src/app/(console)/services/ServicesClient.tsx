'use client';

// The service catalogue (20261103120100): every service customers can request and providers can
// offer, in one list. Adding or renaming one needs no app release, because the apps show the
// stored name. Nothing here deletes: a service is switched off, and keeps its name on past requests.

import { useRef, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { dict } from '@/lib/i18n';
import { newIdempotencyKey } from '@/lib/idempotency';
import { servicesRepository } from '@/lib/repositories';
import type { CatalogueService, ServiceInput } from '@/mocks/types';
import { DataTable, type Column } from '@/components/DataTable';
import { Modal } from '@/components/Modal';
import { StateBlock } from '@/components/StateBlock';
import { StatusChip } from '@/components/StatusChip';
import { adminRoles, can, errorText, formatDateTime, useAdminSession } from '../_shared';
import { useSensitiveAction } from '../config/useSensitiveAction';
import { Field, inputClass, labelClass, primaryButton, secondaryButton } from '../_form';

/** The icon keys the apps know; anything else shows a generic icon. */
const ICONS = [
  'package', 'basket', 'sparkle', 'truck', 'tools', 'person', 'document', 'food', 'car', 'laptop',
  'calendar', 'mechanic', 'fashion', 'beauty', 'plumbing', 'electric', 'carpentry', 'catering',
  'camera', 'school', 'paw', 'magic',
];

interface Draft {
  creating: boolean;
  key: string;
  nameEn: string;
  namePcm: string;
  descriptionEn: string;
  descriptionPcm: string;
  iconKey: string;
  requiresVehicle: boolean;
}

const emptyDraft: Draft = {
  creating: true,
  key: '',
  nameEn: '',
  namePcm: '',
  descriptionEn: '',
  descriptionPcm: '',
  iconKey: 'magic',
  requiresVehicle: false,
};

function draftOf(s: CatalogueService): Draft {
  return {
    creating: false,
    key: s.key,
    nameEn: s.displayNames.en ?? '',
    namePcm: s.displayNames.pcm ?? '',
    descriptionEn: s.descriptions.en ?? '',
    descriptionPcm: s.descriptions.pcm ?? '',
    iconKey: s.iconKey,
    requiresVehicle: s.requiresVehicle,
  };
}

function inputOf(d: Draft): ServiceInput {
  const pick = (pairs: Array<[string, string]>) =>
    Object.fromEntries(pairs.map(([k, v]) => [k, v.trim()]).filter(([, v]) => v !== ''));
  return {
    key: d.key.trim(),
    displayNames: pick([['en', d.nameEn], ['pcm', d.namePcm]]),
    descriptions: pick([['en', d.descriptionEn], ['pcm', d.descriptionPcm]]),
    iconKey: d.iconKey,
    requiresVehicle: d.requiresVehicle,
  };
}

export function ServicesClient() {
  const queryClient = useQueryClient();
  const sessionQuery = useAdminSession();
  const role = adminRoles(sessionQuery.data);
  const mayRead = role !== undefined && can(role, 'services.read');
  const mayManage = role !== undefined && can(role, 'services.manage');
  const { runSensitive, reauthModal } = useSensitiveAction();

  const [draft, setDraft] = useState<Draft | null>(null);
  const [toggling, setToggling] = useState<CatalogueService | null>(null);
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  // One idempotency key per save intent; a retry after a failure reuses it.
  const saveKey = useRef<string | null>(null);

  const servicesQuery = useQuery({
    queryKey: ['services', 'list'],
    queryFn: () => servicesRepository.listServices(),
    enabled: mayRead,
  });

  const refresh = () => void queryClient.invalidateQueries({ queryKey: ['services'] });

  const save = async () => {
    if (!draft) return;
    const input = inputOf(draft);
    saveKey.current ??= newIdempotencyKey();
    const key = saveKey.current;
    setBusy(true);
    setError(null);
    const result = await runSensitive('services.manage', () => servicesRepository.saveService(input, key));
    setBusy(false);
    if (result.ok) {
      saveKey.current = null;
      setDraft(null);
      setNotice(dict.services.saved);
      refresh();
    } else if (result.error) {
      setError(errorText(result.error));
    }
  };

  const toggle = async () => {
    if (!toggling) return;
    const target = toggling;
    setBusy(true);
    setError(null);
    const result = await runSensitive('services.manage', () =>
      servicesRepository.setServiceActive(target.key, !target.active, reason.trim()),
    );
    setBusy(false);
    if (result.ok) {
      setToggling(null);
      setReason('');
      refresh();
    } else if (result.error) {
      setError(errorText(result.error));
    }
  };

  const columns: Column<CatalogueService>[] = [
    {
      key: 'name',
      label: dict.services.columns.name,
      render: (s) => (
        <div className="flex flex-col">
          <span>{s.displayNames.en ?? s.key}</span>
          {s.descriptions.en ? (
            <span className="text-body-small text-ink-secondary dark:text-ink-dark-secondary">{s.descriptions.en}</span>
          ) : null}
        </div>
      ),
    },
    { key: 'key', label: dict.services.columns.key, render: (s) => <code>{s.key}</code> },
    {
      key: 'status',
      label: dict.services.columns.status,
      render: (s) => (
        <StatusChip
          label={s.active ? dict.services.statuses.active : dict.services.statuses.inactive}
          tone={s.active ? 'success' : 'neutral'}
        />
      ),
    },
    {
      key: 'requests',
      label: dict.services.columns.requests,
      render: (s) => `${s.requestCount} (${s.openRequestCount})`,
    },
    { key: 'providers', label: dict.services.columns.providers, render: (s) => String(s.providerCount) },
    { key: 'updated', label: dict.services.columns.updated, render: (s) => formatDateTime(s.updatedAt) },
    {
      key: 'actions',
      label: dict.common.actions,
      render: (s) =>
        mayManage ? (
          <div className="flex gap-xs">
            <button type="button" className={secondaryButton} onClick={() => setDraft(draftOf(s))}>
              {dict.services.edit}
            </button>
            <button
              type="button"
              className={secondaryButton}
              data-testid={`service-toggle-${s.key}`}
              onClick={() => {
                setReason('');
                setError(null);
                setToggling(s);
              }}
            >
              {s.active ? dict.services.switchOff : dict.services.switchOn}
            </button>
          </div>
        ) : null,
    },
  ];

  if (sessionQuery.isPending) return <StateBlock variant="loading" />;
  if (!mayRead) return <StateBlock variant="error" errorMessage={dict.errors.ERR_PERMISSION_DENIED} />;

  const nameOk = draft !== null && draft.nameEn.trim().length >= 2 && /^[a-z0-9_]{2,40}$/.test(draft.key.trim());

  return (
    <div className="flex flex-col gap-xl">
      <div className="flex flex-wrap items-center justify-between gap-md">
        <div className="flex flex-col gap-xs">
          <h1 className="text-headline-medium text-ink-primary dark:text-ink-dark-primary">{dict.services.title}</h1>
          <p className="max-w-3xl text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
            {dict.services.subtitle}
          </p>
        </div>
        {mayManage ? (
          <button
            type="button"
            className={primaryButton}
            onClick={() => {
              saveKey.current = null;
              setError(null);
              setDraft(emptyDraft);
            }}
          >
            {dict.services.add}
          </button>
        ) : null}
      </div>

      {notice ? (
        <p role="status" className="text-body-medium text-success dark:text-success-dark">
          {notice}
        </p>
      ) : null}

      {servicesQuery.isPending ? (
        <StateBlock variant="loading" />
      ) : servicesQuery.isError ? (
        <StateBlock
          variant="error"
          errorMessage={errorText(servicesQuery.error)}
          retryLabel={dict.common.retry}
          onRetry={() => void servicesQuery.refetch()}
        />
      ) : (
        <DataTable columns={columns} rows={servicesQuery.data} keyOf={(s) => s.key} emptyTitle={dict.common.emptyGeneric} />
      )}

      <Modal
        open={draft !== null}
        onClose={() => setDraft(null)}
        title={draft?.creating ? dict.services.editor.createTitle : dict.services.editor.editTitle}
        closeLabel={dict.services.editor.cancel}
      >
        {draft ? (
          <form
            className="flex flex-col gap-md"
            onSubmit={(e) => {
              e.preventDefault();
              if (nameOk && !busy) void save();
            }}
          >
            <Field label={dict.services.editor.key} hint={dict.services.editor.keyHint}>
              <input
                className={inputClass}
                value={draft.key}
                readOnly={!draft.creating}
                onChange={(e) => setDraft({ ...draft, key: e.target.value.toLowerCase() })}
              />
            </Field>
            <Field label={dict.services.editor.nameEn}>
              <input className={inputClass} maxLength={80} value={draft.nameEn} onChange={(e) => setDraft({ ...draft, nameEn: e.target.value })} />
            </Field>
            <Field label={dict.services.editor.namePcm}>
              <input className={inputClass} maxLength={80} value={draft.namePcm} onChange={(e) => setDraft({ ...draft, namePcm: e.target.value })} />
            </Field>
            <Field label={dict.services.editor.descriptionEn}>
              <textarea className={inputClass} maxLength={200} rows={2} value={draft.descriptionEn} onChange={(e) => setDraft({ ...draft, descriptionEn: e.target.value })} />
            </Field>
            <Field label={dict.services.editor.descriptionPcm}>
              <textarea className={inputClass} maxLength={200} rows={2} value={draft.descriptionPcm} onChange={(e) => setDraft({ ...draft, descriptionPcm: e.target.value })} />
            </Field>
            <Field label={dict.services.editor.icon}>
              <select className={inputClass} value={draft.iconKey} onChange={(e) => setDraft({ ...draft, iconKey: e.target.value })}>
                {ICONS.map((icon) => (
                  <option key={icon} value={icon}>
                    {icon}
                  </option>
                ))}
              </select>
            </Field>
            <label className="flex items-center gap-sm">
              <input type="checkbox" checked={draft.requiresVehicle} onChange={(e) => setDraft({ ...draft, requiresVehicle: e.target.checked })} />
              <span className={labelClass}>{dict.services.editor.requiresVehicle}</span>
            </label>
            {error ? (
              <p role="alert" className="text-body-small text-error dark:text-error-dark">
                {error}
              </p>
            ) : null}
            <div className="flex justify-end gap-sm">
              <button type="button" className={secondaryButton} onClick={() => setDraft(null)}>
                {dict.services.editor.cancel}
              </button>
              <button type="submit" className={primaryButton} disabled={!nameOk || busy}>
                {dict.services.editor.save}
              </button>
            </div>
          </form>
        ) : null}
      </Modal>

      <Modal
        open={toggling !== null}
        onClose={() => setToggling(null)}
        title={dict.services.reasonTitle}
        closeLabel={dict.services.editor.cancel}
      >
        {toggling ? (
          <div className="flex flex-col gap-md">
            {toggling.active && toggling.openRequestCount > 0 ? (
              <p className="text-body-medium text-ink-primary dark:text-ink-dark-primary">
                {dict.services.openWarning.replace('{count}', String(toggling.openRequestCount))}
              </p>
            ) : null}
            <Field label={dict.services.reasonLabel}>
              <input className={inputClass} maxLength={300} value={reason} onChange={(e) => setReason(e.target.value)} />
            </Field>
            {error ? (
              <p role="alert" className="text-body-small text-error dark:text-error-dark">
                {error}
              </p>
            ) : null}
            <div className="flex justify-end gap-sm">
              <button type="button" className={secondaryButton} onClick={() => setToggling(null)}>
                {dict.services.editor.cancel}
              </button>
              <button
                type="button"
                className={primaryButton}
                disabled={reason.trim().length < 3 || busy}
                onClick={() => void toggle()}
              >
                {toggling.active ? dict.services.switchOff : dict.services.switchOn}
              </button>
            </div>
          </div>
        ) : null}
      </Modal>

      {reauthModal}
    </div>
  );
}
