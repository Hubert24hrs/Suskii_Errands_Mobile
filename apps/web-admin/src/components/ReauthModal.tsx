'use client';

import { useEffect, useId, useState } from 'react';
import { Modal } from './Modal';

export function ReauthModal({
  open,
  onClose,
  onConfirm,
  title,
  body,
  codeLabel,
  confirmLabel,
  cancelLabel,
  error,
}: {
  open: boolean;
  onClose: () => void;
  onConfirm: (code: string) => void;
  title: string;
  body: string;
  codeLabel: string;
  confirmLabel: string;
  cancelLabel: string;
  error?: string;
}) {
  const id = useId();
  const [code, setCode] = useState('');

  useEffect(() => {
    if (open) setCode('');
  }, [open]);

  return (
    <Modal open={open} onClose={onClose} title={title} closeLabel={cancelLabel}>
      <div className="flex flex-col gap-lg">
        <p className="text-body-large text-ink-primary dark:text-ink-dark-primary">{body}</p>
        <div className="flex flex-col gap-xs">
          <label
            htmlFor={id}
            className="text-label-large text-ink-primary dark:text-ink-dark-primary"
          >
            {codeLabel}
          </label>
          <input
            id={id}
            type="text"
            inputMode="numeric"
            autoComplete="one-time-code"
            value={code}
            onChange={(e) => setCode(e.target.value)}
            className="w-full rounded-md border border-outline bg-surface px-md py-sm text-body-large text-ink-primary outline-none transition-colors duration-normal ease-standard focus:border-brand-primary dark:border-outline-dark dark:bg-surface-dark dark:text-ink-dark-primary"
          />
        </div>
        {error ? (
          <p role="alert" className="text-body-small text-error dark:text-error-dark">
            {error}
          </p>
        ) : null}
        <div className="flex flex-wrap gap-md">
          <button
            type="button"
            disabled={code.trim() === ''}
            onClick={() => onConfirm(code.trim())}
            className="rounded-md bg-brand-primary px-xl py-sm text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong disabled:opacity-50"
          >
            {confirmLabel}
          </button>
          <button
            type="button"
            onClick={onClose}
            className="rounded-md border border-outline px-lg py-sm text-label-large text-ink-primary transition-colors duration-normal ease-standard hover:bg-surface-muted dark:border-outline-dark dark:text-ink-dark-primary dark:hover:bg-surface-dark-muted"
          >
            {cancelLabel}
          </button>
        </div>
      </div>
    </Modal>
  );
}
