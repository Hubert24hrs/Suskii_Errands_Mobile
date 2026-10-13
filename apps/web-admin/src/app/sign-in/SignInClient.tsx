'use client';

import { useEffect, useState, type FormEvent } from 'react';
import { useRouter } from 'next/navigation';
import { dict } from '@/lib/i18n';
import { sessionRepository, usingRealBackend, type TotpEnrolment } from '@/lib/repositories';
import { StateBlock } from '@/components/StateBlock';
import { errorText } from '../(console)/_shared';

const inputClasses =
  'w-full rounded-md border border-outline bg-surface-raised px-md py-sm text-body-large text-ink-primary outline-none transition-colors duration-normal ease-standard focus:border-brand-primary placeholder:text-ink-secondary dark:border-outline-dark dark:bg-surface-dark-raised dark:text-ink-dark-primary dark:placeholder:text-ink-dark-secondary';

const labelClasses = 'text-label-large text-ink-primary dark:text-ink-dark-primary';

export function SignInClient() {
  const router = useRouter();
  const [step, setStep] = useState<'credentials' | 'mfa'>('credentials');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [code, setCode] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [checking, setChecking] = useState(true);
  // First sign-in against the real backend: the authenticator is enrolled here.
  const [enrolment, setEnrolment] = useState<TotpEnrolment | null>(null);
  const hint = usingRealBackend ? dict.auth.liveHint : dict.auth.demoHint;

  // Already signed in → straight to the console.
  useEffect(() => {
    let cancelled = false;
    sessionRepository
      .getSession()
      .then((session) => {
        if (cancelled) return;
        if (session) {
          router.replace('/');
        } else {
          setChecking(false);
        }
      })
      .catch(() => {
        if (!cancelled) setChecking(false);
      });
    return () => {
      cancelled = true;
    };
  }, [router]);

  const submitCredentials = async (e: FormEvent) => {
    e.preventDefault();
    setBusy(true);
    setError(null);
    try {
      const result = await sessionRepository.signIn(email, password);
      // Only the real backend enrols; the mock answers without one.
      setEnrolment((result as { enrolment?: TotpEnrolment }).enrolment ?? null);
      setStep('mfa');
    } catch (err) {
      setError(errorText(err));
    } finally {
      setBusy(false);
    }
  };

  const submitMfa = async (e: FormEvent) => {
    e.preventDefault();
    setBusy(true);
    setError(null);
    try {
      await sessionRepository.verifyMfa(code);
      router.replace('/');
    } catch (err) {
      setError(errorText(err));
    } finally {
      setBusy(false);
    }
  };

  if (checking) {
    return (
      <main className="mx-auto flex min-h-screen w-full max-w-md flex-col justify-center px-lg py-xxxl">
        <StateBlock variant="loading" />
      </main>
    );
  }

  return (
    <main className="mx-auto flex min-h-screen w-full max-w-md flex-col justify-center px-lg py-xxxl">
      <div className="flex items-center gap-sm">
        <span className="flex h-8 w-8 items-center justify-center rounded-sm sk-gradient font-display font-bold">
          S
        </span>
        <span className="text-title-large text-ink-primary dark:text-ink-dark-primary">
          {dict.meta.title}
        </span>
      </div>

      {step === 'credentials' ? (
        <form onSubmit={submitCredentials} className="mt-xxl flex flex-col gap-lg">
          <h1 className="text-headline-medium text-ink-primary dark:text-ink-dark-primary">
            {dict.auth.title}
          </h1>
          <div className="flex flex-col gap-xs">
            <label htmlFor="email" className={labelClasses}>
              {dict.auth.emailLabel}
            </label>
            <input
              id="email"
              type="email"
              autoComplete="username"
              required
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              className={inputClasses}
            />
          </div>
          <div className="flex flex-col gap-xs">
            <label htmlFor="password" className={labelClasses}>
              {dict.auth.passwordLabel}
            </label>
            <input
              id="password"
              type="password"
              autoComplete="current-password"
              required
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              className={inputClasses}
            />
          </div>
          {error ? (
            <p role="alert" className="text-body-small text-error dark:text-error-dark">
              {error}
            </p>
          ) : null}
          <button
            type="submit"
            disabled={busy || email.trim() === '' || password === ''}
            className="rounded-md bg-brand-primary px-xl py-md text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong disabled:opacity-50"
          >
            {dict.auth.signInCta}
          </button>
          <p className="text-body-small text-ink-secondary dark:text-ink-dark-secondary">
            {hint}
          </p>
        </form>
      ) : (
        <form onSubmit={submitMfa} className="mt-xxl flex flex-col gap-lg">
          <h1 className="text-headline-medium text-ink-primary dark:text-ink-dark-primary">
            {enrolment ? dict.auth.enrolTitle : dict.auth.mfaTitle}
          </h1>
          <p className="text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
            {enrolment ? dict.auth.enrolBody : dict.auth.mfaBody}
          </p>
          {enrolment ? (
            <div className="flex flex-col items-center gap-sm rounded-lg border border-outline bg-surface-raised p-lg dark:border-outline-dark dark:bg-surface-dark-raised">
              {/* GoTrue returns the QR as an SVG data URI; it never leaves the browser. */}
              {/* eslint-disable-next-line @next/next/no-img-element */}
              <img
                src={enrolment.qrCode}
                alt={dict.auth.enrolQrAlt}
                width={192}
                height={192}
                className="rounded-md bg-white p-sm"
              />
              <span className="text-label-medium text-ink-secondary dark:text-ink-dark-secondary">
                {dict.auth.enrolSecretLabel}
              </span>
              <code
                data-testid="totp-secret"
                className="break-all text-center font-mono text-body-medium text-ink-primary dark:text-ink-dark-primary"
              >
                {enrolment.secret}
              </code>
            </div>
          ) : null}
          <div className="flex flex-col gap-xs">
            <label htmlFor="mfa-code" className={labelClasses}>
              {dict.auth.mfaCodeLabel}
            </label>
            <input
              id="mfa-code"
              type="text"
              inputMode="numeric"
              autoComplete="one-time-code"
              required
              value={code}
              onChange={(e) => setCode(e.target.value)}
              className={inputClasses}
            />
          </div>
          {error ? (
            <p role="alert" className="text-body-small text-error dark:text-error-dark">
              {error}
            </p>
          ) : null}
          <button
            type="submit"
            disabled={busy || !/^\d{6}$/.test(code.trim())}
            className="rounded-md bg-brand-primary px-xl py-md text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong disabled:opacity-50"
          >
            {dict.auth.mfaVerifyCta}
          </button>
          <p className="text-body-small text-ink-secondary dark:text-ink-dark-secondary">
            {hint}
          </p>
        </form>
      )}
    </main>
  );
}
