'use client';

import { useState } from 'react';
import { useMutation } from '@tanstack/react-query';
import type { Dictionary } from '@/lib/i18n/en';
import { newIdempotencyKey } from '@/lib/idempotency';
import { Modal } from '@/components/Modal';
import { MoneyField } from '@/components/MoneyField';
import { errorText } from './_shared';

/**
 * Withdrawal sheet shared by the wallet and referrals routes. The form is
 * mounted only while the sheet is open, so each open starts a fresh
 * idempotency key (one key per user intent — reused on retry, regenerated
 * when the amount changes).
 */
export function WithdrawalModal({
  open,
  onClose,
  dict,
  currency,
  title,
  confirmCta,
  doneNote,
  onSubmit,
  onSuccess,
}: {
  open: boolean;
  onClose: () => void;
  dict: Dictionary;
  currency: string;
  title: string;
  confirmCta: string;
  doneNote: string;
  onSubmit: (amountMinor: number, idempotencyKey: string) => Promise<unknown>;
  onSuccess: () => void;
}) {
  return (
    <Modal open={open} onClose={onClose} title={title} closeLabel={dict.common.close}>
      {open ? (
        <WithdrawalForm
          dict={dict}
          currency={currency}
          confirmCta={confirmCta}
          doneNote={doneNote}
          onSubmit={onSubmit}
          onSuccess={onSuccess}
          onClose={onClose}
        />
      ) : null}
    </Modal>
  );
}

function WithdrawalForm({
  dict,
  currency,
  confirmCta,
  doneNote,
  onSubmit,
  onSuccess,
  onClose,
}: {
  dict: Dictionary;
  currency: string;
  confirmCta: string;
  doneNote: string;
  onSubmit: (amountMinor: number, idempotencyKey: string) => Promise<unknown>;
  onSuccess: () => void;
  onClose: () => void;
}) {
  const [amountMinor, setAmountMinor] = useState<number | null>(null);
  const [idempotencyKey, setIdempotencyKey] = useState(() => newIdempotencyKey());
  const [done, setDone] = useState(false);

  const mutation = useMutation({
    mutationFn: () => {
      if (amountMinor === null) throw new Error('amount required');
      return onSubmit(amountMinor, idempotencyKey);
    },
    onSuccess: () => {
      setDone(true);
      onSuccess();
    },
  });

  const handleAmountChange = (minor: number | null) => {
    setAmountMinor(minor);
    // A changed amount is a new intent — the old key must not be reused.
    setIdempotencyKey(newIdempotencyKey());
    mutation.reset();
  };

  if (done) {
    return (
      <div className="flex flex-col gap-lg">
        <p className="text-body-large text-ink-primary dark:text-ink-dark-primary">{doneNote}</p>
        <div className="flex justify-end">
          <button
            type="button"
            onClick={onClose}
            className="rounded-md bg-brand-primary px-xl py-sm text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong"
          >
            {dict.common.close}
          </button>
        </div>
      </div>
    );
  }

  return (
    <form
      onSubmit={(e) => {
        e.preventDefault();
        mutation.mutate();
      }}
      className="flex flex-col gap-lg"
    >
      <MoneyField
        label={dict.wallet.withdrawal.amountLabel}
        currency={currency}
        valueMinor={amountMinor}
        onChange={handleAmountChange}
      />
      {mutation.isError ? (
        <p className="text-body-small text-error dark:text-error-dark" role="alert">
          {errorText(dict, mutation.error)}
        </p>
      ) : null}
      <div className="flex justify-end gap-md">
        <button
          type="button"
          onClick={onClose}
          className="rounded-md border border-outline px-xl py-sm text-label-large text-ink-primary transition-colors duration-normal ease-standard hover:bg-surface-muted dark:border-outline-dark dark:text-ink-dark-primary dark:hover:bg-surface-dark-muted"
        >
          {dict.common.cancel}
        </button>
        <button
          type="submit"
          disabled={amountMinor === null || amountMinor <= 0 || mutation.isPending}
          className="rounded-md bg-brand-primary px-xl py-sm text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong disabled:opacity-50"
        >
          {mutation.isPending ? dict.common.loading : confirmCta}
        </button>
      </div>
    </form>
  );
}
