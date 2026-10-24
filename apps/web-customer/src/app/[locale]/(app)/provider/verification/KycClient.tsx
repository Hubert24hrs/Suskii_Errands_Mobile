'use client';

import Link from 'next/link';
import { useRef, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import type { Dictionary } from '@/lib/i18n/en';
import type { Locale } from '@/lib/i18n';
import { bootstrapRepository, mediaUploadRepository, providerKycRepository } from '@/lib/repositories';
import { newIdempotencyKey } from '@/lib/idempotency';
import type { KycStep, KycStepInput, KycStepKind, KycStepStatus, PayoutAccountResult } from '@/mocks/types';
import { StateBlock } from '@/components/StateBlock';
import { StatusChip } from '@/components/StatusChip';
import {
  Notice,
  ProviderPage,
  btnPrimary,
  btnSecondary,
  card,
  errorText,
  inputClass,
  labelClass,
  mutedText,
  pageTitle,
  sectionTitle,
} from '../_shared';

type Feedback = { text: string; tone: 'success' | 'error' } | undefined;

function tone(status: KycStepStatus) {
  switch (status) {
    case 'verified':
      return 'success' as const;
    case 'rejected':
    case 'expired':
      return 'error' as const;
    case 'in_review':
    case 'in_progress':
    case 'consent_pending':
      return 'info' as const;
    default:
      return 'neutral' as const;
  }
}

export function KycClient({ locale, dict }: { locale: Locale; dict: Dictionary }) {
  const t = dict.provider.kyc;
  const queryClient = useQueryClient();
  const profile = useQuery({ queryKey: ['provider', 'kyc'], queryFn: () => providerKycRepository.getKycProfile() });
  const [open, setOpen] = useState<KycStepKind>();
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState<Feedback>();
  const reviewKey = useRef<string>(undefined);

  async function submitForReview() {
    setBusy(true);
    setNotice(undefined);
    reviewKey.current ??= newIdempotencyKey();
    try {
      await providerKycRepository.submitForReview(reviewKey.current);
      reviewKey.current = undefined;
      setNotice({ text: t.submitted, tone: 'success' });
      await queryClient.invalidateQueries({ queryKey: ['provider', 'kyc'] });
    } catch (error) {
      setNotice({ text: errorText(dict, error), tone: 'error' });
    } finally {
      setBusy(false);
    }
  }

  return (
    <ProviderPage locale={locale} dict={dict}>
      <div className="flex flex-wrap items-center justify-between gap-md">
        <h1 className={pageTitle}>{t.title}</h1>
        {profile.data ? (
          <StatusChip label={t.overall[profile.data.overallStatus]} tone={tone(profile.data.overallStatus)} />
        ) : null}
      </div>
      <p className={mutedText}>{t.intro}</p>
      <Link href={`/${locale}/provider/onboarding`} className="text-label-large text-brand-primary hover:underline dark:text-brand-secondary">
        {t.editServices}
      </Link>
      <Notice text={notice?.text} tone={notice?.tone} />
      {profile.isPending ? (
        <StateBlock variant="loading" />
      ) : profile.isError ? (
        <StateBlock variant="error" errorMessage={errorText(dict, profile.error)} retryLabel={dict.common.retry} onRetry={() => void profile.refetch()} />
      ) : (
        <>
          <ul className="flex flex-col gap-md" data-testid="kyc-steps">
            {profile.data.steps.map((step) => (
              <li key={step.kind} className={`${card} flex flex-col gap-md`} data-testid={`kyc-step-${step.kind}`}>
                <div className="flex flex-wrap items-center justify-between gap-sm">
                  <span className={sectionTitle}>{t.steps[step.kind]}</span>
                  <div className="flex items-center gap-sm">
                    <StatusChip label={t.overall[step.status]} tone={tone(step.status)} />
                    {step.status !== 'verified' && step.status !== 'in_review' ? (
                      <button
                        type="button"
                        data-testid={`kyc-open-${step.kind}`}
                        onClick={() => setOpen(open === step.kind ? undefined : step.kind)}
                        className={btnSecondary}
                      >
                        {step.status === 'not_started' ? t.start : t.update}
                      </button>
                    ) : null}
                  </div>
                </div>
                {open === step.kind ? (
                  <StepForm
                    step={step}
                    dict={dict}
                    onDone={() => {
                      setOpen(undefined);
                      setNotice({ text: t.saved, tone: 'success' });
                      void queryClient.invalidateQueries({ queryKey: ['provider', 'kyc'] });
                    }}
                  />
                ) : null}
              </li>
            ))}
          </ul>
          {profile.data.overallStatus !== 'verified' && profile.data.overallStatus !== 'in_review' ? (
            <div>
              <button type="button" data-testid="kyc-submit-review" disabled={busy} onClick={() => void submitForReview()} className={btnPrimary}>
                {t.submit}
              </button>
            </div>
          ) : null}
        </>
      )}
    </ProviderPage>
  );
}

function Field({
  label,
  value,
  onChange,
  type = 'text',
  testId,
}: {
  label: string;
  value: string;
  onChange: (value: string) => void;
  type?: string;
  testId?: string;
}) {
  return (
    <label className="flex flex-col gap-xs">
      <span className={labelClass}>{label}</span>
      <input type={type} data-testid={testId} value={value} onChange={(e) => onChange(e.target.value)} className={inputClass} />
    </label>
  );
}

function FileField({ label, onFile }: { label: string; onFile: (file: File | undefined) => void }) {
  return (
    <label className="flex flex-col gap-xs">
      <span className={labelClass}>{label}</span>
      <input type="file" accept="image/*,application/pdf" onChange={(e) => onFile(e.target.files?.[0])} className="text-body-medium" />
    </label>
  );
}

function StepForm({ step, dict, onDone }: { step: KycStep; dict: Dictionary; onDone: () => void }) {
  const t = dict.provider.kyc;
  const bootstrap = useQuery({ queryKey: ['bootstrap'], queryFn: () => bootstrapRepository.getBootstrap() });
  const [values, setValues] = useState<Record<string, string>>({});
  const [files, setFiles] = useState<Record<string, File | undefined>>({});
  const [consent, setConsent] = useState(false);
  const [resolved, setResolved] = useState<PayoutAccountResult>();
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState<Feedback>();
  const key = useRef<{ forInput: string; key: string }>(undefined);
  const v = (name: string) => values[name] ?? '';
  const set = (name: string) => (value: string) => setValues((current) => ({ ...current, [name]: value }));
  const upload = (file: File) => mediaUploadRepository.upload({ bucket: 'kyc-docs', file });

  async function build(): Promise<KycStepInput | undefined> {
    switch (step.kind) {
      case 'government_id':
        return v('idNumber').trim() ? { kind: 'government_id', idType: v('idType') || 'nin', idNumber: v('idNumber').trim() } : undefined;
      case 'id_document_capture':
        return files.document ? { kind: 'id_document_capture', uploadRef: await upload(files.document) } : undefined;
      case 'police_clearance':
        if (!consent || !files.document || !v('certNumber') || !v('issueDate') || !v('expiryDate')) return undefined;
        return {
          kind: 'police_clearance',
          certificateNumber: v('certNumber').trim(),
          issueDate: v('issueDate'),
          expiryDate: v('expiryDate'),
          uploadRef: await upload(files.document),
        };
      case 'address':
        if (!v('line1').trim() || !v('city').trim() || !v('state')) return undefined;
        return {
          kind: 'address',
          line1: v('line1'),
          line2: v('line2') || undefined,
          city: v('city'),
          state: v('state'),
          landmarkNote: v('landmark') || undefined,
        };
      case 'guarantor':
        if (!v('name').trim() || !/^\+\d{8,15}$/.test(v('phone').trim()) || !v('relationship').trim()) return undefined;
        return { kind: 'guarantor', fullName: v('name'), phoneE164: v('phone').trim(), relationship: v('relationship') };
      case 'payout_account':
        return resolved?.nameMatch ? { kind: 'payout_account', bankCode: v('bankCode'), accountNumber: v('accountNumber') } : undefined;
      case 'vehicle_documents':
        if (!files.licence || !files.registration) return undefined;
        return {
          kind: 'vehicle_documents',
          licenceUploadRef: await upload(files.licence),
          registrationUploadRef: await upload(files.registration),
          insuranceUploadRef: files.insurance ? await upload(files.insurance) : undefined,
        };
      case 'credentials': {
        if (!v('description').trim()) return undefined;
        const refs = files.document ? [await upload(files.document)] : [];
        return { kind: 'credentials', description: v('description'), uploadRefs: refs };
      }
      default:
        return undefined;
    }
  }

  async function submit() {
    setBusy(true);
    setNotice(undefined);
    try {
      const input = await build();
      if (!input) {
        setNotice({ text: dict.errors.ERR_INVALID_ARGUMENT, tone: 'error' });
        return;
      }
      const forInput = JSON.stringify({ ...input, uploadRef: undefined });
      if (key.current?.forInput !== forInput) key.current = { forInput, key: newIdempotencyKey() };
      await providerKycRepository.submitStep(input, key.current.key);
      key.current = undefined;
      onDone();
    } catch (error) {
      setNotice({ text: errorText(dict, error), tone: 'error' });
    } finally {
      setBusy(false);
    }
  }

  async function resolve() {
    setBusy(true);
    setNotice(undefined);
    try {
      setResolved(await providerKycRepository.resolvePayoutAccount({ bankCode: v('bankCode'), accountNumber: v('accountNumber') }));
    } catch (error) {
      setNotice({ text: errorText(dict, error), tone: 'error' });
    } finally {
      setBusy(false);
    }
  }

  if (step.kind === 'provider_facial' || step.kind === 'customer_facial') {
    return <p className={mutedText}>{t.selfieBody}</p>;
  }

  const states = bootstrap.data?.countryPack.serviceAreas ?? [];
  return (
    <div className="flex flex-col gap-md" data-testid={`kyc-form-${step.kind}`}>
      {step.kind === 'government_id' ? (
        <>
          <label className="flex flex-col gap-xs">
            <span className={labelClass}>{t.idType}</span>
            <select value={v('idType') || 'nin'} onChange={(e) => set('idType')(e.target.value)} className={inputClass}>
              {Object.entries(t.idTypes).map(([code, label]) => (
                <option key={code} value={code}>
                  {label}
                </option>
              ))}
            </select>
          </label>
          <Field label={t.idNumber} value={v('idNumber')} onChange={set('idNumber')} testId="kyc-id-number" />
        </>
      ) : null}
      {step.kind === 'id_document_capture' ? <FileField label={t.file} onFile={(f) => setFiles({ document: f })} /> : null}
      {step.kind === 'police_clearance' ? (
        <>
          <Field label={t.certNumber} value={v('certNumber')} onChange={set('certNumber')} />
          <div className="grid gap-md sm:grid-cols-2">
            <Field label={t.issueDate} type="date" value={v('issueDate')} onChange={set('issueDate')} />
            <Field label={t.expiryDate} type="date" value={v('expiryDate')} onChange={set('expiryDate')} />
          </div>
          <FileField label={t.file} onFile={(f) => setFiles({ document: f })} />
          <label className="flex items-start gap-sm text-body-medium">
            <input type="checkbox" checked={consent} onChange={(e) => setConsent(e.target.checked)} />
            {t.consent}
          </label>
        </>
      ) : null}
      {step.kind === 'address' ? (
        <>
          <Field label={t.line1} value={v('line1')} onChange={set('line1')} testId="kyc-address-line1" />
          <Field label={t.line2} value={v('line2')} onChange={set('line2')} />
          <div className="grid gap-md sm:grid-cols-2">
            <Field label={t.city} value={v('city')} onChange={set('city')} testId="kyc-address-city" />
            <label className="flex flex-col gap-xs">
              <span className={labelClass}>{t.stateField}</span>
              <select data-testid="kyc-address-state" value={v('state')} onChange={(e) => set('state')(e.target.value)} className={inputClass}>
                <option value="">{dict.provider.onboarding.stateHint}</option>
                {states.map((s) => (
                  <option key={s.code} value={s.name}>
                    {s.name}
                  </option>
                ))}
              </select>
            </label>
          </div>
          <Field label={t.landmark} value={v('landmark')} onChange={set('landmark')} />
        </>
      ) : null}
      {step.kind === 'guarantor' ? (
        <>
          <Field label={t.guarantorName} value={v('name')} onChange={set('name')} />
          <Field label={t.guarantorPhone} type="tel" value={v('phone')} onChange={set('phone')} />
          <Field label={t.relationship} value={v('relationship')} onChange={set('relationship')} />
        </>
      ) : null}
      {step.kind === 'payout_account' ? (
        <>
          <div className="grid gap-md sm:grid-cols-2">
            <Field label={t.bankCode} value={v('bankCode')} onChange={set('bankCode')} />
            <Field label={t.accountNumber} value={v('accountNumber')} onChange={set('accountNumber')} />
          </div>
          <div>
            <button type="button" disabled={busy || !v('bankCode') || !v('accountNumber')} onClick={() => void resolve()} className={btnSecondary}>
              {t.resolve}
            </button>
          </div>
          {resolved ? (
            <p className={resolved.nameMatch ? 'text-body-medium text-success dark:text-success-dark' : 'text-body-medium text-error dark:text-error-dark'}>
              {resolved.resolvedName} · {resolved.maskedAccountNumber} · {resolved.nameMatch ? t.nameMatch : t.nameNoMatch}
            </p>
          ) : null}
        </>
      ) : null}
      {step.kind === 'vehicle_documents' ? (
        <>
          <FileField label={t.licence} onFile={(f) => setFiles((c) => ({ ...c, licence: f }))} />
          <FileField label={t.registration} onFile={(f) => setFiles((c) => ({ ...c, registration: f }))} />
          <FileField label={t.insurance} onFile={(f) => setFiles((c) => ({ ...c, insurance: f }))} />
        </>
      ) : null}
      {step.kind === 'credentials' ? (
        <>
          <label className="flex flex-col gap-xs">
            <span className={labelClass}>{t.description}</span>
            <textarea value={v('description')} onChange={(e) => set('description')(e.target.value)} rows={3} className={inputClass} />
          </label>
          <FileField label={t.file} onFile={(f) => setFiles({ document: f })} />
        </>
      ) : null}
      <div>
        <button type="button" data-testid={`kyc-save-${step.kind}`} disabled={busy} onClick={() => void submit()} className={btnPrimary}>
          {t.save}
        </button>
      </div>
      <Notice text={notice?.text} tone={notice?.tone} />
    </div>
  );
}
