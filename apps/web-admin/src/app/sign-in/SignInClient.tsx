'use client';

import { useEffect, useState, type FormEvent } from 'react';
import { useRouter } from 'next/navigation';
import { dict } from '@/lib/i18n';
import { sessionRepository } from '@/mocks/repositories';
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
      await sessionRepository.signIn(email, password);
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
        <span className="flex h-8 w-8 items-center justify-center rounded-sm bg-brand-primary font-bold text-brand-on-primary">
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
            {dict.auth.demoHint}
          </p>
        </form>
      ) : (
        <form onSubmit={submitMfa} className="mt-xxl flex flex-col gap-lg">
          <h1 className="text-headline-medium text-ink-primary dark:text-ink-dark-primary">
            {dict.auth.mfaTitle}
          </h1>
          <p className="text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
            {dict.auth.mfaBody}
          </p>
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
            {dict.auth.demoHint}
          </p>
        </form>
      )}
    </main>
  );
}
