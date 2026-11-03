'use client';

// "How would you like to use Suskii Errands?", asked once after sign-up, as the app asks it
// (`select_initial_role`, 20261103120000). Accounts that predate the question count as having
// answered. Choosing Service Provider leads to provider onboarding; provider mode itself opens
// only once the provider is approved, which the server enforces.

import { useRouter } from 'next/navigation';
import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import type { Dictionary } from '@/lib/i18n/en';
import type { Locale } from '@/lib/i18n';
import type { UserMode } from '@/mocks/types';
import { bootstrapRepository, userRepository } from '@/lib/repositories';
import { newIdempotencyKey } from '@/lib/idempotency';
import { errorText } from '@/app/[locale]/(app)/requests/_shared';

export function RoleSelectionGate({ locale, dict }: { locale: Locale; dict: Dictionary }) {
  const t = dict.roleSelection;
  const router = useRouter();
  const queryClient = useQueryClient();
  const bootstrap = useQuery({
    queryKey: ['bootstrap'],
    queryFn: () => bootstrapRepository.getBootstrap(),
    retry: false,
  });
  const [choice, setChoice] = useState<UserMode>();
  // One key per answer: kept on failure so a retry replays it, replaced on a new choice.
  const [key, setKey] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [answered, setAnswered] = useState(false);
  const [error, setError] = useState<string>();

  if (answered || bootstrap.data?.user?.roleSelected !== false) return null;

  function pick(mode: UserMode) {
    if (mode !== choice) setKey(null);
    setChoice(mode);
  }

  async function submit() {
    if (!choice || busy) return;
    const current = key ?? newIdempotencyKey();
    setKey(current);
    setBusy(true);
    setError(undefined);
    try {
      await userRepository.selectInitialRole(choice, current);
      setAnswered(true);
      await queryClient.invalidateQueries({ queryKey: ['bootstrap'] });
      if (choice === 'provider') router.push(`/${locale}/provider/onboarding`);
    } catch (e) {
      setError(errorText(dict, e));
    } finally {
      setBusy(false);
    }
  }

  const cards: ReadonlyArray<{ mode: UserMode; title: string; body: string; icon: string }> = [
    { mode: 'customer', title: t.customerTitle, body: t.customerBody, icon: '🛍️' },
    { mode: 'provider', title: t.providerTitle, body: t.providerBody, icon: '💼' },
  ];

  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-labelledby="role-title"
      data-testid="role-selection"
      className="fixed inset-0 z-50 overflow-y-auto bg-surface px-lg py-xl dark:bg-surface-dark"
    >
      <div className="mx-auto flex w-full max-w-lg flex-col gap-lg">
        <div className="flex flex-col gap-xs text-center">
          <h1 id="role-title" className="text-headline-small text-ink-primary dark:text-ink-dark-primary">
            {t.title}
          </h1>
          <p className="text-body-medium text-ink-secondary dark:text-ink-dark-secondary">{t.subtitle}</p>
        </div>
        <div role="radiogroup" aria-labelledby="role-title" className="flex flex-col gap-md">
          {cards.map((card) => {
            const selected = choice === card.mode;
            return (
              <button
                key={card.mode}
                type="button"
                role="radio"
                aria-checked={selected}
                data-testid={`role-${card.mode}`}
                onClick={() => pick(card.mode)}
                className={`flex items-center gap-md rounded-lg border p-lg text-left transition-colors duration-normal ease-standard ${
                  selected
                    ? 'border-2 border-brand-primary bg-brand-primary/10'
                    : 'border-outline bg-surface-raised hover:bg-surface-muted dark:border-outline-dark dark:bg-surface-dark-raised dark:hover:bg-surface-dark-muted'
                }`}
              >
                <span aria-hidden="true" className="text-[32px] leading-none">
                  {card.icon}
                </span>
                <span className="flex flex-1 flex-col gap-xs">
                  <span className="text-title-medium text-ink-primary dark:text-ink-dark-primary">{card.title}</span>
                  <span className="text-body-medium text-ink-secondary dark:text-ink-dark-secondary">{card.body}</span>
                </span>
              </button>
            );
          })}
        </div>
        {choice === 'provider' ? (
          <p className="text-body-small text-ink-secondary dark:text-ink-dark-secondary">{t.providerNote}</p>
        ) : null}
        {error ? (
          <p role="alert" className="text-body-small text-error dark:text-error-dark">
            {error}
          </p>
        ) : null}
        <button
          type="button"
          data-testid="role-continue"
          disabled={!choice || busy}
          onClick={() => void submit()}
          className="rounded-md bg-brand-primary px-xl py-sm text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong disabled:opacity-50"
        >
          {t.continue}
        </button>
      </div>
    </div>
  );
}
