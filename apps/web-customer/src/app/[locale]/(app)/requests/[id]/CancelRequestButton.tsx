'use client';

import { useState } from 'react';
import type { Dictionary } from '@/lib/i18n/en';
import { newIdempotencyKey } from '@/lib/idempotency';
import { requestRepository } from '@/mocks/repositories';
import { Modal } from '@/components/Modal';
import { errorText } from '../_shared';

const REASON_KEYS = ['changed_mind', 'price_too_high', 'found_elsewhere', 'other'] as const;

export function CancelRequestButton({
  jobId,
  dict,
}: {
  jobId: string;
  dict: Dictionary;
}) {
  const [open, setOpen] = useState(false);
  const [reasonKey, setReasonKey] = useState<string>(REASON_KEYS[0]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // One key per cancel intent; reset when the modal (re)opens or reason changes.
  const [intent, setIntent] = useState<{ key: string; reason: string } | null>(null);

  const submit = async () => {
    const current =
      intent && intent.reason === reasonKey
        ? intent
        : { key: newIdempotencyKey(), reason: reasonKey };
    setIntent(current);
    setBusy(true);
    setError(null);
    try {
      // ERR_JOB_NOT_CANCELLABLE surfaces via errorText with an ERR_INTERNAL
      // fallback until the dict carries the dedicated key.
      await requestRepository.cancelRequest(jobId, reasonKey, current.key);
      setIntent(null);
      setOpen(false);
    } catch (e) {
      setError(errorText(dict, e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <>
      <button
        type="button"
        onClick={() => {
          setError(null);
          setOpen(true);
        }}
        className="rounded-md border border-error px-lg py-sm text-label-large text-error transition-colors duration-normal ease-standard hover:bg-error/10 dark:border-error-dark dark:text-error-dark dark:hover:bg-error-dark/20"
      >
        {dict.requests.cancel.cta}
      </button>

      <Modal
        open={open}
        onClose={() => setOpen(false)}
        title={dict.requests.cancel.title}
        closeLabel={dict.common.close}
      >
        <div className="flex flex-col gap-lg">
          <p className="text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
            {dict.requests.cancel.body}
          </p>
          <fieldset className="flex flex-col gap-xs">
            <legend className="text-label-large text-ink-primary dark:text-ink-dark-primary">
              {dict.requests.cancel.reasonLabel}
            </legend>
            {REASON_KEYS.map((key) => (
              <label
                key={key}
                className="flex items-center gap-sm text-body-medium text-ink-primary dark:text-ink-dark-primary"
              >
                <input
                  type="radio"
                  name="cancel-reason"
                  value={key}
                  checked={reasonKey === key}
                  onChange={() => setReasonKey(key)}
                />
                {dict.requests.cancel.reasons[key]}
              </label>
            ))}
          </fieldset>
          {error ? (
            <p role="alert" className="text-body-small text-error dark:text-error-dark">
              {error}
            </p>
          ) : null}
          <button
            type="button"
            disabled={busy}
            onClick={() => void submit()}
            className="rounded-md bg-error px-xl py-md text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:opacity-90 disabled:opacity-50 dark:bg-error-dark"
          >
            {dict.requests.cancel.confirmCta}
          </button>
        </div>
      </Modal>
    </>
  );
}
