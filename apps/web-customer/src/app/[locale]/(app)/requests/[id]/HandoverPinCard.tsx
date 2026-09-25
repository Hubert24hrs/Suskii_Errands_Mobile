'use client';

import { useState } from 'react';
import type { Dictionary } from '@/lib/i18n/en';
import { jobProgressRepository } from '@/lib/repositories';
import { CopyButton } from '@/components/CopyButton';
import { errorText } from '../_shared';

/**
 * Customer-only handover PINs. PINs are never carried on the job object —
 * the server hands them out on demand via `reveal_job_pin` and rotates on
 * every call, so the card reveals on tap and never caches. Jobs with a
 * destination have both a pickup and a delivery PIN.
 */
export function HandoverPinCard({
  jobId,
  hasDestination,
  dict,
}: {
  jobId: string;
  hasDestination: boolean;
  dict: Dictionary;
}) {
  const [busy, setBusy] = useState(false);
  const [pickupPin, setPickupPin] = useState<string | undefined>(undefined);
  const [deliveryPin, setDeliveryPin] = useState<string | undefined>(undefined);
  const [error, setError] = useState<string | null>(null);

  const reveal = async () => {
    setBusy(true);
    setError(null);
    try {
      const pickup = await jobProgressRepository.revealHandoverPin(jobId, 'pickup');
      const delivery = hasDestination
        ? await jobProgressRepository.revealHandoverPin(jobId, 'delivery')
        : undefined;
      setPickupPin(pickup);
      setDeliveryPin(delivery);
    } catch (e) {
      setError(errorText(dict, e));
    } finally {
      setBusy(false);
    }
  };

  const pinRow = (label: string, pin: string) => (
    <div className="mt-md flex items-center gap-md">
      <span className="text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
        {label}
      </span>
      <span className="text-headline-medium font-bold tracking-widest text-ink-primary dark:text-ink-dark-primary">
        {pin}
      </span>
      <CopyButton
        text={pin}
        label={dict.common.copy}
        copiedLabel={dict.common.copied}
      />
    </div>
  );

  return (
    <section className="rounded-lg border border-outline bg-surface-raised p-xl dark:border-outline-dark dark:bg-surface-dark-raised">
      <h2 className="text-title-large text-ink-primary dark:text-ink-dark-primary">
        {dict.requests.handoverPin.title}
      </h2>
      {pickupPin === undefined ? (
        <>
          <p className="mt-sm text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
            {dict.requests.handoverPin.body}
          </p>
          <button
            type="button"
            disabled={busy}
            onClick={() => void reveal()}
            className="mt-md rounded-md border border-outline px-lg py-sm text-label-large text-ink-primary transition-colors duration-normal ease-standard hover:bg-surface-muted disabled:opacity-50 dark:border-outline-dark dark:text-ink-dark-primary dark:hover:bg-surface-dark-muted"
          >
            {dict.requests.handoverPin.revealCta}
          </button>
        </>
      ) : (
        <>
          {pinRow(dict.requests.handoverPin.pickupLabel, pickupPin)}
          {deliveryPin !== undefined
            ? pinRow(dict.requests.handoverPin.deliveryLabel, deliveryPin)
            : null}
        </>
      )}
      {error ? (
        <p role="alert" className="mt-sm text-body-small text-error dark:text-error-dark">
          {error}
        </p>
      ) : null}
      <p className="mt-md text-body-small text-warning dark:text-warning-dark">
        {dict.requests.handoverPin.rotateWarning}
      </p>
    </section>
  );
}
