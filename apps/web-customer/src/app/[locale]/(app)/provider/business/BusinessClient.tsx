'use client';

import { useRef, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import type { Dictionary } from '@/lib/i18n/en';
import type { Locale } from '@/lib/i18n';
import { catalogRepository, organizationRepository } from '@/lib/repositories';
import { newIdempotencyKey } from '@/lib/idempotency';
import { formatMoney } from '@/lib/money';
import type { BusinessRole, OrgMember, Organization, VehicleType } from '@/mocks/types';
import { Modal } from '@/components/Modal';
import { StateBlock } from '@/components/StateBlock';
import { StatusChip } from '@/components/StatusChip';
import {
  Notice,
  ProviderPage,
  btnDanger,
  btnPrimary,
  btnSecondary,
  card,
  categoryLabel,
  errorText,
  fill,
  inputClass,
  labelClass,
  mutedText,
  pageTitle,
  sectionTitle,
} from '../_shared';

type Feedback = { text: string; tone: 'success' | 'error' } | undefined;

const VEHICLE_TYPES: VehicleType[] = ['motorcycle', 'tricycle', 'car', 'van', 'truck', 'bicycle'];

/** One idempotency key per intent, reused while that intent is retried. */
function useKeys() {
  const keys = useRef<Record<string, string>>({});
  return {
    key: (intent: string) => (keys.current[intent] ??= newIdempotencyKey()),
    done: (intent: string) => {
      delete keys.current[intent];
    },
  };
}

function verificationTone(status: string) {
  return status === 'verified' ? ('success' as const) : status === 'rejected' || status === 'suspended' ? ('error' as const) : ('warning' as const);
}

export function BusinessClient({ locale, dict }: { locale: Locale; dict: Dictionary }) {
  const t = dict.provider.business;
  const org = useQuery({
    queryKey: ['provider', 'org'],
    queryFn: async () => (await organizationRepository.getMyOrganization()) ?? null,
  });

  return (
    <ProviderPage locale={locale} dict={dict}>
      <h1 className={pageTitle}>{t.title}</h1>
      <Invitations dict={dict} />
      {org.isPending ? (
        <StateBlock variant="loading" />
      ) : org.isError ? (
        <StateBlock variant="error" errorMessage={errorText(dict, org.error)} retryLabel={dict.common.retry} onRetry={() => void org.refetch()} />
      ) : org.data === null ? (
        <Register dict={dict} />
      ) : (
        <Console org={org.data} dict={dict} />
      )}
    </ProviderPage>
  );
}

function Invitations({ dict }: { dict: Dictionary }) {
  const t = dict.provider.business;
  const queryClient = useQueryClient();
  const keys = useKeys();
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState<Feedback>();
  const invitations = useQuery({ queryKey: ['provider', 'invitations'], queryFn: () => organizationRepository.getMyInvitations() });
  if (!invitations.data || invitations.data.length === 0) return null;

  async function accept(organizationId: string) {
    const intent = `accept:${organizationId}`;
    setBusy(true);
    setNotice(undefined);
    try {
      await organizationRepository.acceptInvitation(organizationId, keys.key(intent));
      keys.done(intent);
      setNotice({ text: t.accepted, tone: 'success' });
      await queryClient.invalidateQueries({ queryKey: ['provider'] });
    } catch (error) {
      setNotice({ text: errorText(dict, error), tone: 'error' });
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className={`${card} flex flex-col gap-md`} data-testid="business-invitations">
      <h2 className={sectionTitle}>{t.invitations}</h2>
      {invitations.data.map((invitation) => (
        <div key={invitation.organizationId} className="flex flex-wrap items-center justify-between gap-md">
          <p className="text-body-medium text-ink-primary dark:text-ink-dark-primary">
            {fill(t.invitationBody, { business: invitation.organizationName, role: t.roles[invitation.role] })}
          </p>
          <button
            type="button"
            data-testid={`invitation-accept-${invitation.organizationId}`}
            disabled={busy}
            onClick={() => void accept(invitation.organizationId)}
            className={btnPrimary}
          >
            {t.accept}
          </button>
        </div>
      ))}
      <Notice text={notice?.text} tone={notice?.tone} />
    </section>
  );
}

function Register({ dict }: { dict: Dictionary }) {
  const t = dict.provider.business;
  const queryClient = useQueryClient();
  const keys = useKeys();
  const [name, setName] = useState('');
  const [number, setNumber] = useState('');
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState<Feedback>();

  async function submit() {
    const intent = `register:${name.trim()}:${number.trim()}`;
    setBusy(true);
    setNotice(undefined);
    try {
      await organizationRepository.registerOrganization({
        legalName: name.trim(),
        registrationNumber: number.trim(),
        idempotencyKey: keys.key(intent),
      });
      keys.done(intent);
      setNotice({ text: t.registered, tone: 'success' });
      await queryClient.invalidateQueries({ queryKey: ['provider', 'org'] });
    } catch (error) {
      setNotice({ text: errorText(dict, error), tone: 'error' });
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className={`${card} flex flex-col gap-md`} data-testid="business-register">
      <h2 className={sectionTitle}>{t.noneTitle}</h2>
      <p className={mutedText}>{t.noneBody}</p>
      <label className="flex flex-col gap-xs">
        <span className={labelClass}>{t.legalName}</span>
        <input data-testid="business-name" value={name} onChange={(e) => setName(e.target.value)} className={inputClass} />
      </label>
      <label className="flex flex-col gap-xs">
        <span className={labelClass}>{t.registrationNumber}</span>
        <input data-testid="business-number" value={number} onChange={(e) => setNumber(e.target.value)} className={inputClass} />
      </label>
      <div>
        <button
          type="button"
          data-testid="business-register-submit"
          disabled={busy || name.trim().length < 2 || number.trim().length < 4}
          onClick={() => void submit()}
          className={btnPrimary}
        >
          {t.registerSubmit}
        </button>
      </div>
      <Notice text={notice?.text} tone={notice?.tone} />
    </section>
  );
}

function Console({ org, dict }: { org: Organization; dict: Dictionary }) {
  const t = dict.provider.business;
  const members = useQuery({ queryKey: ['provider', 'org', 'members'], queryFn: () => organizationRepository.getMembers() });
  return (
    <>
      <section className={`${card} flex flex-col gap-sm`} data-testid="business-summary">
        <div className="flex flex-wrap items-center justify-between gap-sm">
          <h2 className={sectionTitle}>{org.name}</h2>
          <StatusChip label={dict.provider.kyc.overall[org.verificationStatus === 'pending' ? 'in_review' : (org.verificationStatus as keyof typeof dict.provider.kyc.overall)] ?? org.verificationStatus} tone={verificationTone(org.verificationStatus)} />
        </div>
        <p className={mutedText}>
          {fill(t.membersCount, { count: org.memberCount })} · {fill(t.vehiclesCount, { count: org.activeVehicleCount })} ·{' '}
          {org.payoutAccountSet ? t.payoutReady : t.payoutMissing}
        </p>
      </section>
      <Members dict={dict} members={members.data} error={members.error} retry={() => void members.refetch()} />
      <Vehicles dict={dict} members={members.data ?? []} />
      <Dispatch dict={dict} members={members.data ?? []} />
    </>
  );
}

function Members({
  dict,
  members,
  error,
  retry,
}: {
  dict: Dictionary;
  members?: OrgMember[];
  error: unknown;
  retry: () => void;
}) {
  const t = dict.provider.business;
  const queryClient = useQueryClient();
  const keys = useKeys();
  const [phone, setPhone] = useState('');
  const [role, setRole] = useState<BusinessRole>('worker');
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState<Feedback>();
  const [removing, setRemoving] = useState<OrgMember>();

  async function invite() {
    // Two genuine invitations are two intents: the phone is part of the intent.
    const intent = `invite:${phone.trim()}:${role}`;
    setBusy(true);
    setNotice(undefined);
    try {
      await organizationRepository.inviteMember({ phoneE164: phone.trim(), role, idempotencyKey: keys.key(intent) });
      keys.done(intent);
      setPhone('');
      setNotice({ text: t.inviteSent, tone: 'success' });
      await queryClient.invalidateQueries({ queryKey: ['provider', 'org'] });
    } catch (error) {
      setNotice({ text: errorText(dict, error), tone: 'error' });
    } finally {
      setBusy(false);
    }
  }

  async function remove(member: OrgMember) {
    const intent = `remove:${member.userId}`;
    setBusy(true);
    setNotice(undefined);
    try {
      await organizationRepository.removeMember(member.userId, keys.key(intent));
      keys.done(intent);
      setRemoving(undefined);
      setNotice({ text: t.removed, tone: 'success' });
      await queryClient.invalidateQueries({ queryKey: ['provider', 'org'] });
    } catch (e) {
      setNotice({ text: errorText(dict, e), tone: 'error' });
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className={`${card} flex flex-col gap-md`} data-testid="business-members">
      <h2 className={sectionTitle}>{t.members}</h2>
      {members === undefined ? (
        error ? (
          <StateBlock variant="error" errorMessage={errorText(dict, error)} retryLabel={dict.common.retry} onRetry={retry} />
        ) : (
          <StateBlock variant="loading" />
        )
      ) : members.length === 0 ? (
        <p className={mutedText}>{t.membersEmpty}</p>
      ) : (
        <ul className="flex flex-col gap-sm">
          {members.map((m) => (
            <li key={m.userId} className="flex flex-wrap items-center justify-between gap-sm">
              <div className="flex flex-col">
                <span className="text-body-large text-ink-primary dark:text-ink-dark-primary">{m.displayName}</span>
                <span className={mutedText}>
                  {t.roles[m.role]} · {fill(t.memberJobs, { count: m.jobsCompleted })}
                  {m.earningsToDate ? ` · ${fill(t.memberEarnings, { amount: formatMoney(m.earningsToDate) })}` : ''}
                </span>
              </div>
              <div className="flex items-center gap-sm">
                <StatusChip label={dict.provider.kyc.overall[m.verificationStatus as keyof typeof dict.provider.kyc.overall] ?? m.verificationStatus} tone={verificationTone(m.verificationStatus)} />
                {m.role !== 'owner' ? (
                  <button type="button" disabled={busy} onClick={() => setRemoving(m)} className={btnDanger}>
                    {t.remove}
                  </button>
                ) : null}
              </div>
            </li>
          ))}
        </ul>
      )}
      <div className="grid gap-sm sm:grid-cols-[1fr_auto_auto] sm:items-end">
        <label className="flex flex-col gap-xs">
          <span className={labelClass}>{t.invitePhone}</span>
          <input
            data-testid="invite-phone"
            inputMode="tel"
            placeholder="+2348012345678"
            value={phone}
            onChange={(e) => setPhone(e.target.value)}
            className={inputClass}
          />
        </label>
        <label className="flex flex-col gap-xs">
          <span className={labelClass}>{t.inviteRole}</span>
          <select value={role} onChange={(e) => setRole(e.target.value as BusinessRole)} className={inputClass}>
            <option value="worker">{t.roles.worker}</option>
            <option value="dispatcher">{t.roles.dispatcher}</option>
          </select>
        </label>
        <button type="button" data-testid="invite-send" disabled={busy || !/^\+\d{8,15}$/.test(phone.trim())} onClick={() => void invite()} className={btnPrimary}>
          {t.inviteSend}
        </button>
      </div>
      <Notice text={notice?.text} tone={notice?.tone} />
      <Modal open={removing !== undefined} onClose={() => setRemoving(undefined)} title={t.removeTitle} closeLabel={dict.common.close}>
        <div className="flex flex-col gap-md">
          <p className="text-body-medium text-ink-primary dark:text-ink-dark-primary">{t.removeBody}</p>
          <button type="button" disabled={busy} onClick={() => removing && void remove(removing)} className={btnDanger}>
            {t.remove}
          </button>
        </div>
      </Modal>
    </section>
  );
}

function Vehicles({ dict, members }: { dict: Dictionary; members: OrgMember[] }) {
  const t = dict.provider.business;
  const queryClient = useQueryClient();
  const keys = useKeys();
  const vehicles = useQuery({ queryKey: ['provider', 'org', 'vehicles'], queryFn: () => organizationRepository.getVehicles() });
  const [type, setType] = useState<VehicleType>('motorcycle');
  const [plate, setPlate] = useState('');
  const [expiry, setExpiry] = useState('');
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState<Feedback>();
  const workers = members.filter((m) => m.role !== 'owner' || members.length === 1);

  async function add() {
    const intent = `vehicle:${type}:${plate.trim()}`;
    setBusy(true);
    setNotice(undefined);
    try {
      await organizationRepository.upsertVehicle(
        { type, plate: plate.trim(), documentExpiry: expiry ? new Date(`${expiry}T00:00:00Z`) : undefined },
        keys.key(intent),
      );
      keys.done(intent);
      setPlate('');
      setExpiry('');
      setNotice({ text: t.vehicleSaved, tone: 'success' });
      await queryClient.invalidateQueries({ queryKey: ['provider', 'org'] });
    } catch (error) {
      setNotice({ text: errorText(dict, error), tone: 'error' });
    } finally {
      setBusy(false);
    }
  }

  async function assign(vehicleId: string, workerId: string | undefined) {
    const intent = `assignVehicle:${vehicleId}:${workerId ?? ''}`;
    setBusy(true);
    setNotice(undefined);
    try {
      await organizationRepository.assignVehicle(vehicleId, workerId, keys.key(intent));
      keys.done(intent);
      await queryClient.invalidateQueries({ queryKey: ['provider', 'org', 'vehicles'] });
    } catch (error) {
      setNotice({ text: errorText(dict, error), tone: 'error' });
    } finally {
      setBusy(false);
    }
  }

  const soon = Date.now() + 30 * 86_400_000;
  return (
    <section className={`${card} flex flex-col gap-md`} data-testid="business-vehicles">
      <h2 className={sectionTitle}>{t.vehicles}</h2>
      {vehicles.isPending ? (
        <StateBlock variant="loading" />
      ) : vehicles.isError ? (
        <StateBlock variant="error" errorMessage={errorText(dict, vehicles.error)} retryLabel={dict.common.retry} onRetry={() => void vehicles.refetch()} />
      ) : vehicles.data.length === 0 ? (
        <p className={mutedText}>{t.vehiclesEmpty}</p>
      ) : (
        <ul className="flex flex-col gap-sm">
          {vehicles.data.map((v) => (
            <li key={v.id} className="flex flex-wrap items-center justify-between gap-sm">
              <div className="flex flex-col">
                <span className="text-body-large text-ink-primary dark:text-ink-dark-primary">
                  {dict.provider.onboarding.vehicleTypes[v.type]} · {v.plate}
                </span>
                {v.documentExpiry ? (
                  <span className={v.documentExpiry.getTime() < soon ? 'text-body-small text-warning dark:text-warning-dark' : mutedText}>
                    {v.documentExpiry.getTime() < soon ? `${t.vehicleExpiryWarning} · ` : ''}
                    {t.vehicleExpiry} {v.documentExpiry.toISOString().slice(0, 10)}
                  </span>
                ) : null}
              </div>
              <label className="flex items-center gap-xs text-body-small">
                <span className={mutedText}>{t.vehicleAssign}</span>
                <select
                  value={v.assignedWorkerId ?? ''}
                  disabled={busy}
                  onChange={(e) => void assign(v.id, e.target.value || undefined)}
                  className={inputClass}
                >
                  <option value="">{t.vehicleUnassigned}</option>
                  {workers.map((m) => (
                    <option key={m.userId} value={m.userId}>
                      {m.displayName}
                    </option>
                  ))}
                </select>
              </label>
            </li>
          ))}
        </ul>
      )}
      <div className="grid gap-sm sm:grid-cols-[auto_1fr_auto_auto] sm:items-end">
        <label className="flex flex-col gap-xs">
          <span className={labelClass}>{t.vehicleType}</span>
          <select value={type} onChange={(e) => setType(e.target.value as VehicleType)} className={inputClass}>
            {VEHICLE_TYPES.map((vt) => (
              <option key={vt} value={vt}>
                {dict.provider.onboarding.vehicleTypes[vt]}
              </option>
            ))}
          </select>
        </label>
        <label className="flex flex-col gap-xs">
          <span className={labelClass}>{t.vehiclePlate}</span>
          <input value={plate} onChange={(e) => setPlate(e.target.value)} className={inputClass} />
        </label>
        <label className="flex flex-col gap-xs">
          <span className={labelClass}>{t.vehicleExpiry}</span>
          <input type="date" value={expiry} onChange={(e) => setExpiry(e.target.value)} className={inputClass} />
        </label>
        <button type="button" disabled={busy || plate.trim().length < 4} onClick={() => void add()} className={btnSecondary}>
          {t.vehicleSave}
        </button>
      </div>
      <Notice text={notice?.text} tone={notice?.tone} />
    </section>
  );
}

function Dispatch({ dict, members }: { dict: Dictionary; members: OrgMember[] }) {
  const t = dict.provider.business;
  const queryClient = useQueryClient();
  const keys = useKeys();
  const jobs = useQuery({ queryKey: ['provider', 'org', 'assignable'], queryFn: () => organizationRepository.getAssignableJobs() });
  const categories = useQuery({ queryKey: ['catalog', 'categories'], queryFn: () => catalogRepository.getCategories() });
  const [picked, setPicked] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState<Feedback>();
  const verified = members.filter((m) => m.verificationStatus === 'verified' && m.role !== 'owner');

  async function assign(jobId: string) {
    const workerId = picked[jobId];
    if (!workerId) return;
    const intent = `dispatch:${jobId}:${workerId}`;
    setBusy(true);
    setNotice(undefined);
    try {
      await organizationRepository.assignJob({ jobId, workerId, idempotencyKey: keys.key(intent) });
      keys.done(intent);
      setNotice({ text: t.dispatchAssigned, tone: 'success' });
      await queryClient.invalidateQueries({ queryKey: ['provider', 'org', 'assignable'] });
    } catch (error) {
      setNotice({ text: errorText(dict, error), tone: 'error' });
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className={`${card} flex flex-col gap-md`} data-testid="business-dispatch">
      <h2 className={sectionTitle}>{t.dispatch}</h2>
      {jobs.isPending ? (
        <StateBlock variant="loading" />
      ) : jobs.isError ? (
        <StateBlock variant="error" errorMessage={errorText(dict, jobs.error)} retryLabel={dict.common.retry} onRetry={() => void jobs.refetch()} />
      ) : jobs.data.length === 0 ? (
        <p className={mutedText}>{t.dispatchEmpty}</p>
      ) : verified.length === 0 ? (
        <p className={mutedText}>{t.noVerifiedWorkers}</p>
      ) : (
        <ul className="flex flex-col gap-sm">
          {jobs.data.map((job) => (
            <li key={job.id} className="flex flex-wrap items-center justify-between gap-sm">
              <span className="text-body-medium text-ink-primary dark:text-ink-dark-primary">
                {categoryLabel(dict, categories.data ?? [], job.categoryId)} · {job.pickup.label}
              </span>
              <div className="flex items-center gap-sm">
                <select
                  aria-label={t.dispatchPick}
                  value={picked[job.id] ?? ''}
                  onChange={(e) => setPicked((p) => ({ ...p, [job.id]: e.target.value }))}
                  className={inputClass}
                >
                  <option value="">{t.dispatchPick}</option>
                  {verified.map((m) => (
                    <option key={m.userId} value={m.userId}>
                      {m.displayName}
                    </option>
                  ))}
                </select>
                <button type="button" disabled={busy || !picked[job.id]} onClick={() => void assign(job.id)} className={btnPrimary}>
                  {t.dispatchAssign}
                </button>
              </div>
            </li>
          ))}
        </ul>
      )}
      <Notice text={notice?.text} tone={notice?.tone} />
    </section>
  );
}
