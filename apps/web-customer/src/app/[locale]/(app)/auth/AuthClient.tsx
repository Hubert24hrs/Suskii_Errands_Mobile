'use client';

// Sign-in (W9.2). Phone or email OTP via authRepository — Supabase GoTrue
// when the gateway is configured, the mock persona otherwise (demo hint is
// shown only in the mock case). No passwords, no social buttons yet (they
// stay ERR_FEATURE_UNAVAILABLE behind the scenes).

import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import type { Dictionary } from '@/lib/i18n/en';
import type { Locale } from '@/lib/i18n';
import { authRepository, supabaseGateway } from '@/lib/repositories';
import type { AuthState } from '@/mocks/types';
import { errorText } from '../requests/_shared';

const inputClasses =
  'w-full rounded-md border border-outline bg-surface-raised px-md py-sm text-body-large text-ink-primary outline-none transition-colors duration-normal ease-standard focus:border-brand-primary placeholder:text-ink-secondary disabled:opacity-50 dark:border-outline-dark dark:bg-surface-dark-raised dark:text-ink-dark-primary dark:placeholder:text-ink-dark-secondary';

const primaryButton =
  'w-full rounded-md bg-brand-primary px-lg py-sm text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong disabled:opacity-50';

type Method = 'phone' | 'email';

export function AuthClient({
  locale,
  dict,
}: {
  locale: Locale;
  dict: Dictionary;
}) {
  const router = useRouter();
  const [auth, setAuth] = useState<AuthState>({ status: 'unknown' });
  const [method, setMethod] = useState<Method>('phone');
  const [destination, setDestination] = useState('');
  const [codeSent, setCodeSent] = useState(false);
  const [code, setCode] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => authRepository.authStateChanges(setAuth), []);

  async function sendCode() {
    setBusy(true);
    setError(null);
    try {
      if (method === 'phone') {
        await authRepository.requestPhoneOtp(destination.trim());
      } else {
        await authRepository.requestEmailOtp(destination.trim());
      }
      setCodeSent(true);
    } catch (e) {
      setError(errorText(dict, e));
    } finally {
      setBusy(false);
    }
  }

  async function verify() {
    setBusy(true);
    setError(null);
    try {
      if (method === 'phone') {
        await authRepository.verifyPhoneOtp(destination.trim(), code.trim());
      } else {
        await authRepository.verifyEmailOtp(destination.trim(), code.trim());
      }
      router.push(`/${locale}`);
      router.refresh();
    } catch (e) {
      setError(errorText(dict, e));
    } finally {
      setBusy(false);
    }
  }

  if (auth.status === 'signed_in' && auth.user) {
    return (
      <div className="mx-auto mt-xxl w-full max-w-sm rounded-lg border border-outline bg-surface-raised p-xl dark:border-outline-dark dark:bg-surface-dark-raised">
        <h1 className="text-title-large text-ink-primary dark:text-ink-dark-primary">
          {dict.auth.title}
        </h1>
        <p className="mt-sm text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
          {dict.auth.signedInAs}{' '}
          <span className="font-semibold text-ink-primary dark:text-ink-dark-primary">
            {auth.user.displayName || auth.user.phoneE164 || auth.user.email}
          </span>
        </p>
        <button
          type="button"
          className={`mt-lg ${primaryButton}`}
          onClick={() => router.push(`/${locale}`)}
        >
          {dict.auth.continue}
        </button>
      </div>
    );
  }

  return (
    <div className="mx-auto mt-xxl w-full max-w-sm rounded-lg border border-outline bg-surface-raised p-xl dark:border-outline-dark dark:bg-surface-dark-raised">
      <h1 className="text-title-large text-ink-primary dark:text-ink-dark-primary">
        {dict.auth.title}
      </h1>
      <p className="mt-sm text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
        {dict.auth.subtitle}
      </p>

      {!codeSent && (
        <div className="mt-md flex rounded-md border border-outline p-xs dark:border-outline-dark">
          {(['phone', 'email'] as const).map((m) => (
            <button
              key={m}
              type="button"
              onClick={() => setMethod(m)}
              className={`flex-1 rounded-sm px-md py-xs text-label-large ${
                method === m
                  ? 'bg-brand-primary text-brand-on-primary'
                  : 'text-ink-secondary hover:text-ink-primary dark:text-ink-dark-secondary dark:hover:text-ink-dark-primary'
              }`}
            >
              {m === 'phone' ? dict.auth.phoneTab : dict.auth.emailTab}
            </button>
          ))}
        </div>
      )}

      <form
        className="mt-lg flex flex-col gap-md"
        onSubmit={(e) => {
          e.preventDefault();
          if (busy) return;
          void (codeSent ? verify() : sendCode());
        }}
      >
        {!codeSent ? (
          <label className="flex flex-col gap-xs">
            <span className="text-label-large text-ink-primary dark:text-ink-dark-primary">
              {method === 'phone' ? dict.auth.phoneLabel : dict.auth.emailLabel}
            </span>
            <input
              className={inputClasses}
              type={method === 'phone' ? 'tel' : 'email'}
              value={destination}
              onChange={(e) => setDestination(e.target.value)}
              placeholder={
                method === 'phone' ? dict.auth.phoneHint : dict.auth.emailHint
              }
              autoComplete={method === 'phone' ? 'tel' : 'email'}
              required
              disabled={busy}
            />
          </label>
        ) : (
          <>
            <p className="text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
              {dict.auth.codeSentTo}{' '}
              <span className="font-semibold text-ink-primary dark:text-ink-dark-primary">
                {destination}
              </span>
            </p>
            <label className="flex flex-col gap-xs">
              <span className="text-label-large text-ink-primary dark:text-ink-dark-primary">
                {dict.auth.codeLabel}
              </span>
              <input
                className={`${inputClasses} tracking-widest`}
                type="text"
                inputMode="numeric"
                value={code}
                onChange={(e) => setCode(e.target.value)}
                autoComplete="one-time-code"
                required
                disabled={busy}
              />
            </label>
          </>
        )}

        {error && (
          <p role="alert" className="text-body-medium text-error dark:text-error-dark">
            {error}
          </p>
        )}

        <button type="submit" className={primaryButton} disabled={busy}>
          {codeSent
            ? busy
              ? dict.auth.verifying
              : dict.auth.verify
            : busy
              ? dict.auth.sending
              : dict.auth.sendCode}
        </button>

        {codeSent && (
          <button
            type="button"
            className="text-label-large text-brand-primary hover:underline"
            onClick={() => {
              setCodeSent(false);
              setCode('');
              setError(null);
            }}
            disabled={busy}
          >
            {dict.auth.changeDestination}
          </button>
        )}
      </form>

      {!supabaseGateway && (
        <p className="mt-lg text-body-small text-ink-secondary dark:text-ink-dark-secondary">
          {dict.auth.demoHint}
        </p>
      )}
    </div>
  );
}
