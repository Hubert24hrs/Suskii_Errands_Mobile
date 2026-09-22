'use client';

import { useEffect, useState } from 'react';
import type { Dictionary } from '@/lib/i18n/en';
import { newIdempotencyKey } from '@/lib/idempotency';
import { isAppError, verificationRepository } from '@/mocks/repositories';
import type { LivenessSession, VerificationSession } from '@/mocks/types';
import { StateBlock } from '@/components/StateBlock';

/** Maps any error to localized copy; unknown codes fall back to ERR_INTERNAL. */
function errorText(dict: Dictionary, error: unknown): string {
  if (isAppError(error)) {
    const table = dict.errors as Record<string, string>;
    return table[error.code] ?? dict.errors.ERR_INTERNAL;
  }
  return dict.errors.ERR_INTERNAL;
}

/** Fallback for dict keys not yet added — renders the key path (reported missing). */
function missingKey(dict: Dictionary, path: string): string {
  const value = path.split('.').reduce<unknown>(
    (acc, part) => (acc && typeof acc === 'object' ? (acc as Record<string, unknown>)[part] : undefined),
    dict,
  );
  return typeof value === 'string' ? value : path;
}

// ID types accepted by the mock ID lookup. dict.verify.idTypes.* keys are not
// in the dictionary yet — the wire values render as-is until they are.
const ID_TYPES = ['nin', 'drivers_license', 'voters_card', 'intl_passport'] as const;

const inputClass =
  'rounded-md border border-outline bg-surface-raised px-md py-sm text-body-large text-ink-primary outline-none transition-colors duration-normal ease-standard focus:border-brand-primary dark:border-outline-dark dark:bg-surface-dark-raised dark:text-ink-dark-primary';

const primaryButtonClass =
  'rounded-md bg-brand-primary px-xl py-md text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong disabled:opacity-50';

type LivenessPhase = 'idle' | 'capturing' | 'failed' | 'passed';

function ConsentStep({
  dict,
  busy,
  error,
  onConsent,
}: {
  dict: Dictionary;
  busy: boolean;
  error: string | null;
  onConsent: () => void;
}) {
  const [checked, setChecked] = useState(false);
  return (
    <div className="flex flex-col gap-lg">
      <h2 className="text-title-large text-ink-primary dark:text-ink-dark-primary">
        {dict.verify.consentTitle}
      </h2>
      <p className="text-body-large text-ink-secondary dark:text-ink-dark-secondary">
        {dict.verify.consentBody}
      </p>
      <label
        htmlFor="biometric-consent"
        className="flex items-start gap-sm text-body-medium text-ink-primary dark:text-ink-dark-primary"
      >
        <input
          id="biometric-consent"
          type="checkbox"
          checked={checked}
          onChange={(e) => setChecked(e.target.checked)}
          className="mt-xs h-5 w-5 accent-brand-primary"
        />
        {dict.verify.consentCheckbox}
      </label>
      {error ? (
        <p role="alert" className="text-body-small text-error dark:text-error-dark">
          {error}
        </p>
      ) : null}
      <div>
        <button
          type="button"
          disabled={!checked || busy}
          onClick={onConsent}
          className={primaryButtonClass}
        >
          {dict.verify.consentCta}
        </button>
      </div>
    </div>
  );
}

function IdLookupForm({
  dict,
  session,
}: {
  dict: Dictionary;
  session: VerificationSession;
}) {
  const [idType, setIdType] = useState<string>(ID_TYPES[0]);
  const [idNumber, setIdNumber] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // One key per lookup intent; reset after success or when inputs change.
  const [intent, setIntent] = useState<{ key: string; fingerprint: string } | null>(null);

  const submit = async () => {
    const fingerprint = `${idType}|${idNumber}`;
    const current =
      intent && intent.fingerprint === fingerprint
        ? intent
        : { key: newIdempotencyKey(), fingerprint };
    setIntent(current);
    setBusy(true);
    setError(null);
    try {
      await verificationRepository.submitIdLookup(session.id, idType, idNumber.trim(), current.key);
      // The session flips to in_review (then verified) via watchCustomerVerification.
      setIntent(null);
    } catch (e) {
      setError(errorText(dict, e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="mt-lg flex flex-col gap-lg border-t border-outline pt-lg dark:border-outline-dark">
      <p className="text-body-large text-success dark:text-success-dark">
        {dict.verify.livenessSuccess}
      </p>
      <div className="flex flex-col gap-xs">
        <label
          htmlFor="id-type"
          className="text-label-large text-ink-primary dark:text-ink-dark-primary"
        >
          {missingKey(dict, 'verify.idTypeLabel')}
        </label>
        <select
          id="id-type"
          value={idType}
          onChange={(e) => setIdType(e.target.value)}
          className={inputClass}
        >
          {ID_TYPES.map((type) => (
            <option key={type} value={type}>
              {missingKey(dict, `verify.idTypes.${type}`)}
            </option>
          ))}
        </select>
      </div>
      <div className="flex flex-col gap-xs">
        <label
          htmlFor="id-number"
          className="text-label-large text-ink-primary dark:text-ink-dark-primary"
        >
          {missingKey(dict, 'verify.idNumberLabel')}
        </label>
        <input
          id="id-number"
          type="text"
          value={idNumber}
          onChange={(e) => setIdNumber(e.target.value)}
          className={inputClass}
        />
      </div>
      {error ? (
        <p role="alert" className="text-body-small text-error dark:text-error-dark">
          {error}
        </p>
      ) : null}
      <div>
        <button
          type="button"
          disabled={busy || idNumber.trim() === ''}
          onClick={() => void submit()}
          className={primaryButtonClass}
        >
          {missingKey(dict, 'verify.idSubmitCta')}
        </button>
      </div>
    </div>
  );
}

function LivenessStep({
  dict,
  session,
}: {
  dict: Dictionary;
  session: VerificationSession;
}) {
  const [phase, setPhase] = useState<LivenessPhase>('idle');
  const [error, setError] = useState<string | null>(null);
  // One key per facial-verification start; retries of the same attempt reuse it.
  const [startKey, setStartKey] = useState<string | null>(null);

  const start = async () => {
    const key = startKey ?? newIdempotencyKey();
    setStartKey(key);
    setError(null);
    setPhase('capturing');
    try {
      // Consent is already recorded; this (re)asserts in_progress and throws
      // ERR_CONSENT_REQUIRED if the session is still consent_pending.
      await verificationRepository.startFacialVerification(key);
      const liveness: LivenessSession = await verificationRepository.startLivenessSession();
      const result = await verificationRepository.captureLiveness(liveness.sessionId);
      if (result.outcome === 'success') {
        setPhase('passed');
        setStartKey(null);
      } else {
        setPhase('failed');
        setStartKey(null);
      }
    } catch (e) {
      setPhase('idle');
      setError(errorText(dict, e));
    }
  };

  return (
    <div className="flex flex-col gap-lg">
      <h2 className="text-title-large text-ink-primary dark:text-ink-dark-primary">
        {dict.verify.livenessTitle}
      </h2>
      <p className="text-body-large text-ink-secondary dark:text-ink-dark-secondary">
        {dict.verify.livenessInstruction}
      </p>

      {phase === 'capturing' ? (
        <p aria-busy="true" className="text-body-large text-ink-primary dark:text-ink-dark-primary">
          {dict.verify.livenessChecking}
        </p>
      ) : null}

      {phase === 'failed' ? (
        <div className="flex flex-col gap-md">
          <p role="alert" className="text-body-large text-error dark:text-error-dark">
            {dict.verify.livenessFailure}
          </p>
          <div>
            <button type="button" onClick={() => void start()} className={primaryButtonClass}>
              {dict.verify.livenessRetry}
            </button>
          </div>
        </div>
      ) : null}

      {phase === 'idle' ? (
        <>
          {error ? (
            <p role="alert" className="text-body-small text-error dark:text-error-dark">
              {error}
            </p>
          ) : null}
          <div>
            <button type="button" onClick={() => void start()} className={primaryButtonClass}>
              {dict.verify.livenessStart}
            </button>
          </div>
        </>
      ) : null}

      {phase === 'passed' ? <IdLookupForm dict={dict} session={session} /> : null}
    </div>
  );
}

export function VerifyClient({ dict }: { dict: Dictionary }) {
  const [session, setSession] = useState<VerificationSession | undefined>(undefined);
  const [watched, setWatched] = useState(false);
  // The watch emits the current session immediately, then live changes
  // (in_review → verified after the mock review delay).
  useEffect(
    () =>
      verificationRepository.watchCustomerVerification((s) => {
        setSession(s);
        setWatched(true);
      }),
    [],
  );

  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // One key per consent intent; retries after failure reuse it.
  const [consentKey, setConsentKey] = useState<string | null>(null);

  const giveConsent = async () => {
    const key = consentKey ?? newIdempotencyKey();
    setConsentKey(key);
    setBusy(true);
    setError(null);
    try {
      await verificationRepository.giveBiometricConsent(key);
      setConsentKey(null);
    } catch (e) {
      setError(errorText(dict, e));
    } finally {
      setBusy(false);
    }
  };

  const needsConsent = !session || session.status === 'consent_pending';

  return (
    <div className="mx-auto w-full max-w-5xl px-lg py-xxxl">
      <h1 className="text-headline-medium text-ink-primary dark:text-ink-dark-primary">
        {dict.verify.title}
      </h1>

      <div className="mt-xxl rounded-lg border border-outline bg-surface-raised p-xl dark:border-outline-dark dark:bg-surface-dark-raised">
        {!watched ? (
          <StateBlock variant="loading" />
        ) : session?.status === 'verified' ? (
          <div className="flex flex-col gap-md">
            <p className="text-title-large text-success dark:text-success-dark">
              {dict.verify.resultVerified}
            </p>
            <p className="text-body-large text-ink-secondary dark:text-ink-dark-secondary">
              {dict.verify.resultVerifiedBody}
            </p>
          </div>
        ) : session?.status === 'in_review' ? (
          <p className="text-body-large text-ink-primary dark:text-ink-dark-primary">
            {dict.verify.resultPending}
          </p>
        ) : session?.status === 'rejected' ? (
          <p role="alert" className="text-body-large text-error dark:text-error-dark">
            {dict.verify.resultRejected}
          </p>
        ) : needsConsent ? (
          <ConsentStep dict={dict} busy={busy} error={error} onConsent={() => void giveConsent()} />
        ) : (
          <LivenessStep dict={dict} session={session} />
        )}
      </div>
    </div>
  );
}
