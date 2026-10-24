'use client';

import type { Dictionary } from '@/lib/i18n/en';
import type { Locale } from '@/lib/i18n';
import { ModeSwitchButton } from '@/components/ModeSwitch';

/** The home card for provider mode: the same switch as the header's, on every screen size. */
export function ProviderModeCard({ locale, dict }: { locale: Locale; dict: Dictionary }) {
  const card = dict.dashboard.cards[dict.dashboard.cards.length - 1];
  return (
    <ModeSwitchButton
      locale={locale}
      dict={dict}
      testId="dashboard-provider"
      className="rounded-lg border border-outline bg-surface-raised p-xl text-left transition-colors duration-normal ease-standard hover:border-brand-primary disabled:opacity-60 dark:border-outline-dark dark:bg-surface-dark-raised dark:hover:border-brand-secondary"
    >
      <h2 className="text-title-large text-ink-primary dark:text-ink-dark-primary">{card.title}</h2>
      <p className="mt-sm text-body-medium text-ink-secondary dark:text-ink-dark-secondary">{card.body}</p>
    </ModeSwitchButton>
  );
}
