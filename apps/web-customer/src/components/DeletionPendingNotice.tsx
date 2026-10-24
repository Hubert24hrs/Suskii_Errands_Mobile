'use client';

// Shown on every signed-in page while the account is scheduled for erasure, as the app shows
// its deletion-pending screen after signing back in. Keeping it cancels the deletion
// (`cancel_account_deletion`); continuing signs out and lets the grace period run.

import { useRouter } from 'next/navigation';
import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import type { Dictionary } from '@/lib/i18n/en';
import type { Locale } from '@/lib/i18n';
import { authRepository, bootstrapRepository, settingsRepository } from '@/lib/repositories';
import { newIdempotencyKey } from '@/lib/idempotency';
import { errorText } from '@/app/[locale]/(app)/requests/_shared';

export function DeletionPendingNotice({ locale, dict }: { locale: Locale; dict: Dictionary }) {
  const t = dict.deletionPending;
  const router = useRouter();
  const queryClient = useQueryClient();
  const bootstrap = useQuery({
    queryKey: ['bootstrap'],
    queryFn: () => bootstrapRepository.getBootstrap(),
    retry: false,
  });
  const [key, setKey] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState<{ text: string; tone: 'success' | 'error' }>();

  const when = bootstrap.data?.accountDeletionScheduledFor;
  if (!when && notice?.tone !== 'success') return null;

  async function keep() {
    // One key for the keep intent; a retry after a failure reuses it.
    const current = key ?? newIdempotencyKey();
    setKey(current);
    setBusy(true);
    setNotice(undefined);
    try {
      await settingsRepository.cancelAccountDeletion(current);
      setKey(null);
      setNotice({ text: t.kept, tone: 'success' });
      await queryClient.invalidateQueries({ queryKey: ['bootstrap'] });
    } catch (error) {
      setNotice({ text: errorText(dict, error), tone: 'error' });
    } finally {
      setBusy(false);
    }
  }

  async function leave() {
    setBusy(true);
    try {
      await authRepository.signOut();
    } finally {
      setBusy(false);
      router.push(`/${locale}`);
      router.refresh();
    }
  }

  if (!when) {
    return (
      <p role="status" data-testid="deletion-kept" className="mx-auto w-full max-w-5xl px-lg pt-lg text-body-medium text-success dark:text-success-dark">
        {notice?.text}
      </p>
    );
  }

  // en-NG for both locales, as settings does: pcm has no Intl locale data.
  const date = new Intl.DateTimeFormat('en-NG', { dateStyle: 'long' }).format(when);
  return (
    <div className="mx-auto w-full max-w-5xl px-lg pt-lg">
      <section
        data-testid="deletion-pending"
        className="flex flex-col gap-md rounded-lg border border-error/40 bg-surface-raised p-xl dark:border-error-dark/40 dark:bg-surface-dark-raised"
      >
        <h2 className="text-title-large text-ink-primary dark:text-ink-dark-primary">{t.title}</h2>
        <p className="text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
          {t.body.replace('{date}', date)}
        </p>
        <div className="flex flex-wrap gap-sm">
          <button
            type="button"
            data-testid="deletion-keep"
            disabled={busy}
            onClick={() => void keep()}
            className="rounded-md bg-brand-primary px-xl py-sm text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong disabled:opacity-50"
          >
            {t.keep}
          </button>
          <button
            type="button"
            disabled={busy}
            onClick={() => void leave()}
            className="rounded-md px-xl py-sm text-label-large text-ink-secondary transition-colors duration-normal ease-standard hover:text-ink-primary disabled:opacity-50 dark:text-ink-dark-secondary dark:hover:text-ink-dark-primary"
          >
            {t.continue}
          </button>
        </div>
        {notice?.tone === 'error' ? (
          <p role="alert" className="text-body-small text-error dark:text-error-dark">
            {notice.text}
          </p>
        ) : null}
      </section>
    </div>
  );
}
