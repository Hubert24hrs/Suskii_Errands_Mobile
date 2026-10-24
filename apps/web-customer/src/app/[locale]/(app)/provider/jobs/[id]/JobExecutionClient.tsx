'use client';

import Link from 'next/link';
import { useEffect, useRef, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import type { Dictionary } from '@/lib/i18n/en';
import type { Locale } from '@/lib/i18n';
import {
  ErrorCodes,
  catalogRepository,
  isAppError,
  mediaUploadRepository,
  providerJobRepository,
  requestRepository,
} from '@/lib/repositories';
import { newIdempotencyKey } from '@/lib/idempotency';
import type { GeoPoint, HandoverPinKind, JobRequest, JobStatus, ProofKind } from '@/mocks/types';
import { Modal } from '@/components/Modal';
import { MoneyText } from '@/components/MoneyText';
import { StateBlock } from '@/components/StateBlock';
import { StatusChip } from '@/components/StatusChip';
import {
  Notice,
  ProviderPage,
  btnPrimary,
  btnSecondary,
  card,
  categoryLabel,
  errorText,
  fill,
  formatDateTime,
  inputClass,
  mutedText,
  pageTitle,
  sectionTitle,
  statusLabel,
  statusTone,
  urgencyLabel,
} from '../../_shared';

const MANUAL_REASONS = ['gps_unavailable', 'customer_moved', 'building_access'] as const;

function currentPosition(): Promise<{ point: GeoPoint; accuracy?: number } | undefined> {
  return new Promise((resolve) => {
    if (typeof navigator === 'undefined' || !navigator.geolocation) return resolve(undefined);
    navigator.geolocation.getCurrentPosition(
      (p) => resolve({ point: { latitude: p.coords.latitude, longitude: p.coords.longitude }, accuracy: p.coords.accuracy }),
      () => resolve(undefined),
      { enableHighAccuracy: true, timeout: 10_000, maximumAge: 30_000 },
    );
  });
}

export function JobExecutionClient({ locale, jobId, dict }: { locale: Locale; jobId: string; dict: Dictionary }) {
  const t = dict.provider.execution;
  const queryClient = useQueryClient();
  const [job, setJob] = useState<JobRequest | undefined>(undefined);
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState<{ text: string; tone: 'success' | 'error' }>();
  const [manualOpen, setManualOpen] = useState(false);
  const [reason, setReason] = useState<(typeof MANUAL_REASONS)[number]>('gps_unavailable');
  // One key per intent, kept across retries of that intent.
  const keys = useRef<Record<string, string>>({});
  const keyFor = (intent: string) => (keys.current[intent] ??= newIdempotencyKey());

  useEffect(() => requestRepository.watchJob(jobId, setJob), [jobId]);
  const categories = useQuery({ queryKey: ['catalog', 'categories'], queryFn: () => catalogRepository.getCategories() });
  const executing = job?.status === 'in_progress' || job?.status === 'completed_by_provider';
  const proofs = useQuery({
    queryKey: ['provider', 'proofs', jobId],
    queryFn: () => providerJobRepository.getProofs(jobId),
    enabled: executing,
  });

  const sharing = useLiveLocation(job, t);

  async function transition(target: JobStatus, extra: { location?: GeoPoint; reasonCode?: string } = {}) {
    const intent = `status:${target}:${extra.reasonCode ?? ''}`;
    setBusy(true);
    setNotice(undefined);
    try {
      const updated = await providerJobRepository.requestStatusChange(jobId, target, {
        idempotencyKey: keyFor(intent),
        ...extra,
      });
      delete keys.current[intent];
      setJob(updated);
      setManualOpen(false);
      await queryClient.invalidateQueries({ queryKey: ['provider'] });
    } catch (error) {
      if (target === 'arrived' && isAppError(error, ErrorCodes.notAtPickup)) {
        setManualOpen(true);
      } else {
        setNotice({ text: errorText(dict, error), tone: 'error' });
      }
    } finally {
      setBusy(false);
    }
  }

  async function arrive() {
    const fix = await currentPosition();
    if (!fix) {
      setManualOpen(true);
      return;
    }
    await transition('arrived', { location: fix.point });
  }

  if (job === undefined) {
    return (
      <ProviderPage locale={locale} dict={dict}>
        <StateBlock variant="loading" />
      </ProviderPage>
    );
  }

  const requiredProofs = Object.entries(
    categories.data?.find((c) => c.id === job.categoryId)?.proofRequirements ?? {},
  ) as [ProofKind, number][];
  const proofKinds: ProofKind[] = requiredProofs.length > 0 ? requiredProofs.map(([k]) => k) : ['photo'];

  return (
    <ProviderPage locale={locale} dict={dict}>
      <div className="flex flex-wrap items-center justify-between gap-md">
        <h1 className={pageTitle}>{categoryLabel(dict, categories.data ?? [], job.categoryId)}</h1>
        <StatusChip label={statusLabel(dict, job.status)} tone={statusTone(job.status)} />
      </div>
      <Link href={`/${locale}/provider/jobs`} className="text-label-large text-brand-primary hover:underline dark:text-brand-secondary">
        {t.back}
      </Link>

      <section className={`${card} flex flex-col gap-md`}>
        <p className="text-body-large text-ink-primary dark:text-ink-dark-primary">{job.description}</p>
        <dl className="grid grid-cols-[auto_1fr] gap-x-lg gap-y-xs text-body-medium">
          <dt className={mutedText}>{dict.requests.detail.pickup}</dt>
          <dd className="text-ink-primary dark:text-ink-dark-primary">{job.pickup.label}</dd>
          {job.pickup.landmarkNote ? (
            <>
              <dt className={mutedText}>{dict.requests.detail.landmark}</dt>
              <dd className="text-ink-primary dark:text-ink-dark-primary">{job.pickup.landmarkNote}</dd>
            </>
          ) : null}
          {job.destination ? (
            <>
              <dt className={mutedText}>{dict.requests.detail.destination}</dt>
              <dd className="text-ink-primary dark:text-ink-dark-primary">{job.destination.label}</dd>
            </>
          ) : null}
          <dt className={mutedText}>{dict.requests.detail.urgency}</dt>
          <dd className="text-ink-primary dark:text-ink-dark-primary">{urgencyLabel(dict, job.urgency)}</dd>
          {job.scheduledAt ? (
            <>
              <dt className={mutedText}>{dict.requests.detail.schedule}</dt>
              <dd className="text-ink-primary dark:text-ink-dark-primary">{formatDateTime(job.scheduledAt)}</dd>
            </>
          ) : null}
          {job.itemFloat ? (
            <>
              <dt className={mutedText}>{dict.requests.detail.itemFloat}</dt>
              <dd>
                <MoneyText amountMinor={job.itemFloat.amountMinor} currency={job.itemFloat.currency} />
              </dd>
            </>
          ) : null}
          {job.agreedPrice ? (
            <>
              <dt className={mutedText}>{t.agreedPrice}</dt>
              <dd>
                <MoneyText amountMinor={job.agreedPrice.amountMinor} currency={job.agreedPrice.currency} />
              </dd>
            </>
          ) : null}
          {job.agreedBreakdown ? (
            <>
              <dt className={mutedText}>{t.payout}</dt>
              <dd>
                <MoneyText
                  amountMinor={job.agreedBreakdown.providerPayout.amountMinor}
                  currency={job.agreedBreakdown.providerPayout.currency}
                />
              </dd>
            </>
          ) : null}
        </dl>
        <div>
          <Link href={`/${locale}/provider/jobs/${job.id}/chat`} className={btnSecondary}>
            {t.chat}
          </Link>
        </div>
      </section>

      <section className="flex flex-col gap-md" data-testid="job-actions">
        {job.status === 'paid_held' || job.status === 'assigned' ? (
          <button type="button" data-testid="job-start" disabled={busy} onClick={() => void transition('en_route')} className={btnPrimary}>
            {t.startJourney}
          </button>
        ) : null}

        {job.status === 'en_route' ? (
          <div className="flex flex-col gap-sm">
            {sharing ? <p className={mutedText}>{sharing}</p> : null}
            <button type="button" data-testid="job-arrived" disabled={busy} onClick={() => void arrive()} className={btnPrimary}>
              {t.arrived}
            </button>
            <p className={mutedText}>{t.arrivalNote}</p>
          </div>
        ) : null}

        {job.status === 'arrived' ? (
          <PinForm jobId={job.id} kind="pickup" dict={dict} />
        ) : null}

        {executing ? (
          <div className="flex flex-col gap-lg">
            <ProofSection
              jobId={job.id}
              kinds={proofKinds}
              dict={dict}
              proofs={proofs.data ?? []}
              onAdded={() => {
                setNotice(undefined);
                void proofs.refetch();
              }}
              editable={job.status === 'in_progress'}
            />
            {job.status === 'in_progress' && job.destination ? (
              <PinForm jobId={job.id} kind="delivery" dict={dict} />
            ) : null}
            {job.status === 'in_progress' ? (
              <button
                type="button"
                data-testid="job-complete"
                disabled={busy}
                onClick={() => void transition('completed_by_provider')}
                className={btnPrimary}
              >
                {t.markComplete}
              </button>
            ) : (
              <p className={`${card} text-body-medium`}>{t.waitingConfirm}</p>
            )}
          </div>
        ) : null}

        {['confirmed', 'settlement_pending', 'settled', 'closed'].includes(job.status) ? (
          <p className={`${card} text-body-medium`}>{t.done}</p>
        ) : null}

        <Notice text={notice?.text} tone={notice?.tone} />
      </section>

      <Modal open={manualOpen} onClose={() => setManualOpen(false)} title={t.manualTitle} closeLabel={dict.common.close}>
        <div className="flex flex-col gap-md">
          <p className="text-body-medium text-ink-primary dark:text-ink-dark-primary">{t.manualBody}</p>
          <fieldset className="flex flex-col gap-sm">
            {MANUAL_REASONS.map((code) => (
              <label key={code} className="flex items-center gap-sm text-body-medium">
                <input type="radio" name="arrival-reason" checked={reason === code} onChange={() => setReason(code)} />
                {t.reasons[code]}
              </label>
            ))}
          </fieldset>
          <button
            type="button"
            data-testid="job-arrived-manual"
            disabled={busy}
            onClick={() => void transition('arrived', { reasonCode: reason })}
            className={btnPrimary}
          >
            {t.confirmArrival}
          </button>
        </div>
      </Modal>
    </ProviderPage>
  );
}

/** While the provider travels, their position goes to the customer's map (ADR-0009). */
function useLiveLocation(job: JobRequest | undefined, t: Dictionary['provider']['execution']): string | undefined {
  const [state, setState] = useState<'idle' | 'sharing' | 'off'>('idle');
  const traveling = job?.status === 'en_route';
  const jobId = job?.id;
  useEffect(() => {
    if (!traveling || !jobId || typeof navigator === 'undefined' || !navigator.geolocation) return;
    let last = 0;
    const watch = navigator.geolocation.watchPosition(
      (p) => {
        setState('sharing');
        const now = Date.now();
        if (now - last < 5_000) return;
        last = now;
        void providerJobRepository
          .publishProviderLocation(jobId, { latitude: p.coords.latitude, longitude: p.coords.longitude }, p.coords.accuracy)
          .catch(() => undefined);
      },
      () => setState('off'),
      { enableHighAccuracy: true, maximumAge: 5_000 },
    );
    return () => navigator.geolocation.clearWatch(watch);
  }, [traveling, jobId]);
  if (!traveling) return undefined;
  return state === 'sharing' ? t.sharingLocation : state === 'off' ? t.locationOff : undefined;
}

/** A verified pickup PIN moves the job to in progress; the job watch picks that up. */
function PinForm({ jobId, kind, dict }: { jobId: string; kind: HandoverPinKind; dict: Dictionary }) {
  const t = dict.provider.execution;
  const [pin, setPin] = useState('');
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState<{ text: string; tone: 'success' | 'error' }>();
  // A retry of the same PIN replays the earlier answer without spending an attempt.
  const keys = useRef<Record<string, string>>({});

  async function verify() {
    setBusy(true);
    setNotice(undefined);
    const key = (keys.current[pin] ??= newIdempotencyKey());
    try {
      const result = await providerJobRepository.verifyHandoverPin(jobId, pin, kind, key);
      if (result.verified) {
        setNotice({ text: t.pinVerified, tone: 'success' });
      } else {
        setNotice({ text: fill(t.pinWrong, { count: result.attemptsRemaining }), tone: 'error' });
      }
    } catch (error) {
      setNotice({ text: errorText(dict, error), tone: 'error' });
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className={`${card} flex flex-col gap-sm`} data-testid={`pin-${kind}`}>
      <span className={sectionTitle}>{kind === 'pickup' ? t.pickupPin : t.deliveryPin}</span>
      <p className={mutedText}>{t.pinHint}</p>
      <div className="flex flex-wrap gap-sm">
        <input
          aria-label={kind === 'pickup' ? t.pickupPin : t.deliveryPin}
          data-testid={`pin-input-${kind}`}
          inputMode="numeric"
          maxLength={6}
          value={pin}
          onChange={(e) => setPin(e.target.value.replace(/\D/g, ''))}
          className={`${inputClass} max-w-[10rem] tracking-[0.5em]`}
        />
        <button type="button" data-testid={`pin-verify-${kind}`} disabled={busy || pin.length !== 6} onClick={() => void verify()} className={btnPrimary}>
          {t.verifyPin}
        </button>
      </div>
      <Notice text={notice?.text} tone={notice?.tone} />
    </div>
  );
}

function ProofSection({
  jobId,
  kinds,
  dict,
  proofs,
  onAdded,
  editable,
}: {
  jobId: string;
  kinds: ProofKind[];
  dict: Dictionary;
  proofs: { id: string; kind: ProofKind; createdAt: Date }[];
  onAdded: () => void;
  editable: boolean;
}) {
  const t = dict.provider.execution;
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState<{ text: string; tone: 'success' | 'error' }>();

  async function add(kind: ProofKind, file: File) {
    setBusy(true);
    setNotice(undefined);
    try {
      // Upload first, then record: the server refuses a path with nothing behind it.
      const storagePath = await mediaUploadRepository.upload({ bucket: 'job-proofs', file, requestId: jobId });
      await providerJobRepository.submitProof({
        jobId,
        kind,
        storagePath,
        idempotencyKey: newIdempotencyKey(),
        capturedAt: new Date(file.lastModified || Date.now()),
      });
      setNotice({ text: t.proofAdded, tone: 'success' });
      onAdded();
    } catch (error) {
      setNotice({ text: errorText(dict, error), tone: 'error' });
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className={`${card} flex flex-col gap-sm`} data-testid="job-proofs">
      <span className={sectionTitle}>{t.proofs}</span>
      <p className={mutedText}>{t.proofsNote}</p>
      {proofs.length === 0 ? (
        <p className={mutedText}>{t.proofsEmpty}</p>
      ) : (
        <ul className="flex flex-col gap-xs text-body-medium">
          {proofs.map((p) => (
            <li key={p.id} className="first-letter:uppercase">
              {t.proofKinds[p.kind]} · {formatDateTime(p.createdAt)}
            </li>
          ))}
        </ul>
      )}
      {editable ? (
        <div className="flex flex-wrap gap-sm">
          {kinds.map((kind) => (
            <label key={kind} className={`${btnSecondary} cursor-pointer`}>
              {fill(t.addProof, { kind: t.proofKinds[kind] })}
              <input
                type="file"
                accept="image/*"
                capture="environment"
                className="sr-only"
                data-testid={`proof-input-${kind}`}
                disabled={busy}
                onChange={(e) => {
                  const file = e.target.files?.[0];
                  e.target.value = '';
                  if (file) void add(kind, file);
                }}
              />
            </label>
          ))}
        </div>
      ) : null}
      <Notice text={notice?.text} tone={notice?.tone} />
    </div>
  );
}
