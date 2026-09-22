'use client';

import { useEffect, useRef, type ReactNode } from 'react';

export function Drawer({
  open,
  onClose,
  title,
  closeLabel,
  wide = false,
  children,
}: {
  open: boolean;
  onClose: () => void;
  title: string;
  closeLabel: string;
  wide?: boolean;
  children: ReactNode;
}) {
  const panelRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose();
    };
    document.addEventListener('keydown', onKeyDown);
    panelRef.current?.focus();
    return () => document.removeEventListener('keydown', onKeyDown);
  }, [open, onClose]);

  if (!open) return null;

  return (
    <div className="fixed inset-0 z-50 bg-ink-primary/40" onClick={onClose}>
      <div
        ref={panelRef}
        role="dialog"
        aria-modal="true"
        aria-label={title}
        tabIndex={-1}
        className={`absolute inset-y-0 right-0 flex w-full flex-col overflow-y-auto border-l border-outline bg-surface-raised outline-none dark:border-outline-dark dark:bg-surface-dark-raised ${
          wide ? 'max-w-2xl' : 'max-w-md'
        }`}
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-center justify-between gap-md border-b border-outline px-xl py-lg dark:border-outline-dark">
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
        <div className="flex-1 px-xl py-lg">{children}</div>
      </div>
    </div>
  );
}
