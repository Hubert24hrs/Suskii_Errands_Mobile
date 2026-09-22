'use client';

// Admin user management (super admin only — the mock enforces
// adminUsers.read / adminUsers.manage server-side). Non-super-admins see
// the gate note and nothing else. Every mutation is sensitive: reauth
// within 5 minutes via useSensitiveAction, one idempotency key per intent.

import { useEffect, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { dict } from '@/lib/i18n';
import { newIdempotencyKey } from '@/lib/idempotency';
import { adminUsersRepository } from '@/mocks/repositories';
import type { AdminRole, AdminUser } from '@/mocks/types';
import { DataTable, type Column } from '@/components/DataTable';
import { Drawer } from '@/components/Drawer';
import { Modal } from '@/components/Modal';
import { StateBlock } from '@/components/StateBlock';
import { StatusChip } from '@/components/StatusChip';
import { errorText, formatDateTime, isSessionError, roleLabel, useAdminSession } from '../_shared';
import { useSensitiveAction } from '../config/useSensitiveAction';

const ROLES = Object.keys(dict.roles) as AdminRole[];

const inputClasses =
  'w-full rounded-md border border-outline bg-surface-raised px-md py-sm text-body-large text-ink-primary outline-none transition-colors duration-normal ease-standard focus:border-brand-primary dark:border-outline-dark dark:bg-surface-dark-raised dark:text-ink-dark-primary';
const labelClasses = 'text-label-large text-ink-primary dark:text-ink-dark-primary';
const primaryButton =
  'rounded-md bg-brand-primary px-lg py-sm text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong disabled:opacity-50';
const secondaryButton =
  'rounded-md border border-outline px-lg py-sm text-label-large text-ink-primary transition-colors duration-normal ease-standard hover:bg-surface-muted disabled:opacity-50 dark:border-outline-dark dark:text-ink-dark-primary dark:hover:bg-surface-dark-muted';
const dangerButton =
  'rounded-md border border-error px-lg py-sm text-label-large text-error transition-colors duration-normal ease-standard hover:bg-error/10 disabled:opacity-50 dark:border-error-dark dark:text-error-dark dark:hover:bg-error-dark/20';

function mfaChip(admin: AdminUser) {
  return (
    <StatusChip
      label={admin.mfaEnrolled ? dict.adminUsers.mfa.enrolled : dict.adminUsers.mfa.notEnrolled}
      tone={admin.mfaEnrolled ? 'success' : 'neutral'}
    />
  );
}

function statusChip(admin: AdminUser) {
  return (
    <StatusChip
      label={admin.active ? dict.adminUsers.statuses.active : dict.adminUsers.statuses.deactivated}
      tone={admin.active ? 'success' : 'error'}
    />
  );
}

export function AdminUsersClient() {
  const router = useRouter();
  const queryClient = useQueryClient();
  const sessionQuery = useAdminSession();
  const role = sessionQuery.data?.admin.role;

  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [deactivateTarget, setDeactivateTarget] = useState<AdminUser | null>(null);
  const [inviteOpen, setInviteOpen] = useState(false);
  const [inviteName, setInviteName] = useState('');
  const [inviteEmail, setInviteEmail] = useState('');
  const [inviteRole, setInviteRole] = useState<AdminRole>('support_agent');
  const [drawerRole, setDrawerRole] = useState<AdminRole | ''>('');
  const [actionError, setActionError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  // One key per intent; the fingerprint (inputs) is part of the key name so
  // changing an input starts a fresh intent, and keys drop after success.
  const intentKeys = useRef<Record<string, string>>({});
  const keyFor = (name: string) => (intentKeys.current[name] ??= newIdempotencyKey());
  const dropKey = (name: string) => {
    delete intentKeys.current[name];
  };

  const { runSensitive, reauthModal } = useSensitiveAction();

  const isSuperAdmin = role === 'super_admin';
  const adminsQuery = useQuery({
    queryKey: ['adminUsers'],
    queryFn: () => adminUsersRepository.listAdmins(),
    enabled: isSuperAdmin,
    retry: false,
  });

  useEffect(() => {
    if (adminsQuery.error && isSessionError(adminsQuery.error)) {
      router.replace('/sign-in');
    }
  }, [adminsQuery.error, router]);

  const refresh = () => void queryClient.invalidateQueries({ queryKey: ['adminUsers'] });

  const run = async (fn: () => Promise<unknown>, onSuccess?: () => void) => {
    setBusy(true);
    setActionError(null);
    const result = await runSensitive('adminUsers.manage', fn);
    if (result.ok) {
      onSuccess?.();
      refresh();
    } else if (result.error != null) {
      // Includes the mock's self-change / self-deactivate ERR_INVALID_STATE.
      setActionError(errorText(result.error));
    }
    setBusy(false);
  };

  const sendInvite = () => {
    const name = inviteName.trim();
    const email = inviteEmail.trim();
    if (name === '' || email === '') return;
    const keyName = `invite:${email.toLowerCase()}:${inviteRole}`;
    void run(
      () => adminUsersRepository.invite({ name, email, role: inviteRole }, keyFor(keyName)),
      () => {
        dropKey(keyName);
        setInviteOpen(false);
        setInviteName('');
        setInviteEmail('');
        setInviteRole('support_agent');
      },
    );
  };

  const changeRole = (admin: AdminUser) => {
    if (drawerRole === '' || drawerRole === admin.role) return;
    const nextRole = drawerRole;
    const keyName = `role:${admin.id}:${nextRole}`;
    void run(
      () => adminUsersRepository.changeRole(admin.id, nextRole, keyFor(keyName)),
      () => dropKey(keyName),
    );
  };

  const toggleActive = (admin: AdminUser) => {
    const next = !admin.active;
    const keyName = `active:${admin.id}:${next}`;
    void run(
      () => adminUsersRepository.setActive(admin.id, next, keyFor(keyName)),
      () => dropKey(keyName),
    );
  };

  const enforceMfa = (admin: AdminUser) => {
    const keyName = `mfa:${admin.id}`;
    void run(
      () => adminUsersRepository.enforceMfa(admin.id, keyFor(keyName)),
      () => dropKey(keyName),
    );
  };

  if (sessionQuery.isPending) {
    return <StateBlock variant="loading" />;
  }

  // The whole page is super-admin only.
  if (!isSuperAdmin) {
    return (
      <StateBlock variant="empty" emptyTitle={dict.adminUsers.superAdminOnlyNote} />
    );
  }

  if (adminsQuery.isPending) {
    return <StateBlock variant="loading" />;
  }
  if (adminsQuery.isError) {
    return (
      <StateBlock
        variant="error"
        errorMessage={errorText(adminsQuery.error)}
        retryLabel={dict.common.retry}
        onRetry={() => void adminsQuery.refetch()}
      />
    );
  }

  const selected = adminsQuery.data.find((a) => a.id === selectedId);

  const columns: Column<AdminUser>[] = [
    { key: 'name', label: dict.adminUsers.columns.name },
    { key: 'email', label: dict.adminUsers.columns.email },
    {
      key: 'role',
      label: dict.adminUsers.columns.role,
      render: (admin) => roleLabel(admin.role),
    },
    {
      key: 'mfa',
      label: dict.adminUsers.columns.mfa,
      render: (admin) => mfaChip(admin),
    },
    {
      key: 'status',
      label: dict.adminUsers.columns.status,
      render: (admin) => statusChip(admin),
    },
  ];

  return (
    <div className="flex flex-col gap-xl">
      <div className="flex flex-wrap items-center justify-between gap-md">
        <h1 className="text-headline-medium text-ink-primary dark:text-ink-dark-primary">
          {dict.adminUsers.title}
        </h1>
        <button type="button" onClick={() => setInviteOpen(true)} className={primaryButton}>
          {dict.adminUsers.invite.cta}
        </button>
      </div>

      <p className="text-body-small text-ink-secondary dark:text-ink-dark-secondary">
        {dict.adminUsers.mfa.enforceNote}
      </p>

      <DataTable
        columns={columns}
        rows={adminsQuery.data}
        keyOf={(a) => a.id}
        emptyTitle={dict.common.emptyGeneric}
        onRowClick={(admin) => {
          setActionError(null);
          setDrawerRole('');
          setSelectedId(admin.id);
        }}
      />

      {actionError !== null && selectedId === null ? (
        <p role="alert" className="text-body-medium text-error dark:text-error-dark">
          {actionError}
        </p>
      ) : null}

      <Drawer
        open={selected !== undefined}
        onClose={() => setSelectedId(null)}
        title={selected?.name ?? ''}
        closeLabel={dict.common.close}
      >
        {selected ? (
          <div className="flex flex-col gap-lg">
            <div className="flex flex-col gap-sm">
              <p className="text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
                {selected.email}
              </p>
              <div className="flex flex-wrap gap-sm">
                {statusChip(selected)}
                {mfaChip(selected)}
              </div>
              <p className="text-body-small text-ink-secondary dark:text-ink-dark-secondary">
                {formatDateTime(selected.createdAt)}
              </p>
            </div>

            <div className="flex flex-col gap-xs">
              <label htmlFor="drawer-role" className={labelClasses}>
                {dict.adminUsers.columns.role}
              </label>
              <div className="flex flex-wrap items-center gap-sm">
                <select
                  id="drawer-role"
                  value={drawerRole === '' ? selected.role : drawerRole}
                  onChange={(e) => setDrawerRole(e.target.value as AdminRole)}
                  className={inputClasses}
                >
                  {ROLES.map((r) => (
                    <option key={r} value={r}>
                      {roleLabel(r)}
                    </option>
                  ))}
                </select>
                <button
                  type="button"
                  disabled={busy || drawerRole === '' || drawerRole === selected.role}
                  onClick={() => changeRole(selected)}
                  className={secondaryButton}
                >
                  {dict.adminUsers.changeRoleCta}
                </button>
              </div>
            </div>

            {!selected.mfaEnrolled ? (
              <button
                type="button"
                disabled={busy}
                onClick={() => enforceMfa(selected)}
                className={`${secondaryButton} w-fit`}
              >
                {dict.adminUsers.mfa.enforceCta}
              </button>
            ) : null}

            <div>
              <button
                type="button"
                disabled={busy}
                onClick={() =>
                  selected.active ? setDeactivateTarget(selected) : toggleActive(selected)
                }
                className={selected.active ? dangerButton : primaryButton}
              >
                {selected.active ? dict.adminUsers.deactivateCta : dict.adminUsers.activateCta}
              </button>
            </div>

            {actionError !== null ? (
              <p role="alert" className="text-body-medium text-error dark:text-error-dark">
                {actionError}
              </p>
            ) : null}
          </div>
        ) : null}
      </Drawer>

      <Modal
        open={deactivateTarget !== null}
        onClose={() => setDeactivateTarget(null)}
        title={dict.adminUsers.deactivateCta}
        closeLabel={dict.common.close}
      >
        <div className="flex flex-col gap-lg">
          <p className="text-body-medium text-ink-primary dark:text-ink-dark-primary">
            {dict.adminUsers.deactivateNote}
          </p>
          <div className="flex flex-wrap gap-md">
            <button
              type="button"
              disabled={busy}
              onClick={() => {
                const target = deactivateTarget;
                if (!target) return;
                const next = false;
                const keyName = `active:${target.id}:${next}`;
                void run(
                  () => adminUsersRepository.setActive(target.id, next, keyFor(keyName)),
                  () => {
                    dropKey(keyName);
                    setDeactivateTarget(null);
                  },
                );
              }}
              className={dangerButton}
            >
              {dict.adminUsers.deactivateCta}
            </button>
            <button
              type="button"
              onClick={() => setDeactivateTarget(null)}
              className={secondaryButton}
            >
              {dict.common.cancel}
            </button>
          </div>
        </div>
      </Modal>

      <Modal
        open={inviteOpen}
        onClose={() => setInviteOpen(false)}
        title={dict.adminUsers.invite.title}
        closeLabel={dict.common.close}
      >
        <form
          className="flex flex-col gap-lg"
          onSubmit={(e) => {
            e.preventDefault();
            sendInvite();
          }}
        >
          <div className="flex flex-col gap-xs">
            <label htmlFor="invite-name" className={labelClasses}>
              {dict.adminUsers.invite.nameLabel}
            </label>
            <input
              id="invite-name"
              type="text"
              value={inviteName}
              onChange={(e) => setInviteName(e.target.value)}
              className={inputClasses}
            />
          </div>
          <div className="flex flex-col gap-xs">
            <label htmlFor="invite-email" className={labelClasses}>
              {dict.adminUsers.invite.emailLabel}
            </label>
            <input
              id="invite-email"
              type="email"
              value={inviteEmail}
              onChange={(e) => setInviteEmail(e.target.value)}
              className={inputClasses}
            />
          </div>
          <div className="flex flex-col gap-xs">
            <label htmlFor="invite-role" className={labelClasses}>
              {dict.adminUsers.invite.roleLabel}
            </label>
            <select
              id="invite-role"
              value={inviteRole}
              onChange={(e) => setInviteRole(e.target.value as AdminRole)}
              className={inputClasses}
            >
              {ROLES.map((r) => (
                <option key={r} value={r}>
                  {roleLabel(r)}
                </option>
              ))}
            </select>
          </div>
          <div className="flex flex-wrap gap-md">
            <button
              type="submit"
              disabled={busy || inviteName.trim() === '' || inviteEmail.trim() === ''}
              className={primaryButton}
            >
              {dict.adminUsers.invite.sendCta}
            </button>
            <button
              type="button"
              onClick={() => setInviteOpen(false)}
              className={secondaryButton}
            >
              {dict.common.cancel}
            </button>
          </div>
        </form>
      </Modal>

      {reauthModal}
    </div>
  );
}
