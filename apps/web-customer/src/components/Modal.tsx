'use client';

import { useEffect, useRef, type ReactNode } from 'react';

export function Modal({
  open,
  onClose,
  title,
  closeLabel,
  children,
}: {
  open: boolean;
  onClose: () => void;
  title: string;
  closeLabel: string;
  children: ReactNode;
}) {
  const dialogRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose();
    };
    document.addEventListener('keydown', onKeyDown);
    dialogRef.current?.focus();
    return () => document.removeEventListener('keydown', onKeyDown);
  }, [open, onClose]);

  if (!open) return null;

  return (
    <div
      className="fixed inset-0 z-50 flex items-end justify-center bg-ink-primary/40 p-md sm:items-center"
      onClick={onClose}
    >
      <div
        ref={dialogRef}
        role="dialog"
        aria-modal="true"
        aria-label={title}
        tabIndex={-1}
        className="w-full max-w-md rounded-lg bg-surface-raised p-xl outline-none dark:bg-surface-dark-raised"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-center justify-between gap-md">
          <h2 className="text-title-large text-ink-primary dark:text-ink-dark-primary">{title}</h2>
          <button
            type="button"
            onClick={onClose}
            aria-label={closeLabel}
            className="rounded-sm px-sm py-xs text-label-large text-ink-secondary transition-colors duration-normal ease-standard hover:text-ink-primary dark:text-ink-dark-secondary dark:hover:text-ink-dark-primary"
          >
            ✕
          </button>
        </div>
        <div className="mt-lg">{children}</div>
      </div>
    </div>
  );
}
