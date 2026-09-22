'use client';

import { useState } from 'react';
import type { Dictionary } from '@/lib/i18n/en';
import { CopyButton } from '@/components/CopyButton';

/**
 * Customer-only handover PIN. The mock carries the PIN on the job object
 * (set by the server when the job is agreed); revealing is a local toggle.
 */
export function HandoverPinCard({ pin, dict }: { pin: string; dict: Dictionary }) {
  const [revealed, setRevealed] = useState(false);

  return (
    <section className="rounded-lg border border-outline bg-surface-raised p-xl dark:border-outline-dark dark:bg-surface-dark-raised">
      <h2 className="text-title-large text-ink-primary dark:text-ink-dark-primary">
        {dict.requests.handoverPin.title}
      </h2>
      <p className="mt-sm text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
        {dict.requests.handoverPin.body}
      </p>
      {revealed ? (
        <div className="mt-md flex items-center gap-md">
          <span className="text-headline-medium font-bold tracking-widest text-ink-primary dark:text-ink-dark-primary">
            {pin}
          </span>
          <CopyButton
            text={pin}
            label={dict.common.copy}
            copiedLabel={dict.common.copied}
          />
        </div>
      ) : (
        <button
          type="button"
          onClick={() => setRevealed(true)}
          className="mt-md rounded-md border border-outline px-lg py-sm text-label-large text-ink-primary transition-colors duration-normal ease-standard hover:bg-surface-muted dark:border-outline-dark dark:text-ink-dark-primary dark:hover:bg-surface-dark-muted"
        >
          {dict.requests.handoverPin.revealCta}
        </button>
      )}
      <p className="mt-md text-body-small text-warning dark:text-warning-dark">
        {dict.requests.handoverPin.rotateWarning}
      </p>
    </section>
  );
}
