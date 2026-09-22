'use client';

// Sensitive-action runner for the console: wraps a mutating call so that
// ERR_REAUTH_REQUIRED opens the ReauthModal, re-authenticates via
// sessionRepository.reauth(purpose), then retries the SAME mutation with
// the SAME idempotency key. ERR_SESSION_EXPIRED / ERR_UNAUTHENTICATED
// redirect to /sign-in. All other errors are returned to the caller.

import { useRef, useState, type ReactNode } from 'react';
import { useRouter } from 'next/navigation';
import { dict } from '@/lib/i18n';
import { isAppError, sessionRepository } from '@/mocks/repositories';
import { ReauthModal } from '@/components/ReauthModal';
import { errorText, isSessionError } from '../_shared';

export type SensitiveResult = { ok: true } | { ok: false; error: unknown };

export function useSensitiveAction(): {
  runSensitive: (purpose: string, fn: () => Promise<unknown>) => Promise<SensitiveResult>;
  reauthModal: ReactNode;
} {
  const router = useRouter();
  const [reauthOpen, setReauthOpen] = useState(false);
  const [reauthError, setReauthError] = useState<string | null>(null);
  const pendingRef = useRef<{
    purpose: string;
    fn: () => Promise<unknown>;
    resolve: (r: SensitiveResult) => void;
  } | null>(null);

  const execute = async (
    purpose: string,
    fn: () => Promise<unknown>,
  ): Promise<SensitiveResult> => {
    try {
      await fn();
      return { ok: true };
    } catch (error) {
      if (isAppError(error, 'ERR_REAUTH_REQUIRED')) {
        setReauthError(null);
        setReauthOpen(true);
        return new Promise<SensitiveResult>((resolve) => {
          pendingRef.current = { purpose, fn, resolve };
        });
      }
      if (isSessionError(error)) {
        router.replace('/sign-in');
      }
      return { ok: false, error };
    }
  };

  const confirmReauth = async (_code: string) => {
    const pending = pendingRef.current;
    if (!pending) {
      setReauthOpen(false);
      return;
    }
    try {
      // The mock records the purpose in the audit log; the authenticator
      // code itself is not verified at this layer.
      await sessionRepository.reauth(pending.purpose);
    } catch (e) {
      if (isSessionError(e)) {
        router.replace('/sign-in');
      } else {
        setReauthError(errorText(e));
      }
      return;
    }
    setReauthOpen(false);
    pendingRef.current = null;
    pending.resolve(await execute(pending.purpose, pending.fn));
  };

  const cancelReauth = () => {
    setReauthOpen(false);
    const pending = pendingRef.current;
    pendingRef.current = null;
    pending?.resolve({ ok: false, error: null });
  };

  const reauthModal = (
    <ReauthModal
      open={reauthOpen}
      onClose={cancelReauth}
      onConfirm={(code) => void confirmReauth(code)}
      title={dict.auth.reauth.title}
      body={dict.auth.reauth.body}
      codeLabel={dict.auth.mfaCodeLabel}
      confirmLabel={dict.auth.reauth.confirmCta}
      cancelLabel={dict.common.cancel}
      error={reauthError ?? undefined}
    />
  );

  return { runSensitive: execute, reauthModal };
}
