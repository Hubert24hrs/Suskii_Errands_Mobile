'use client';

import { useId, type ReactNode } from 'react';

export function FilterBar({
  searchLabel,
  searchPlaceholder,
  searchValue,
  onSearchChange,
  children,
}: {
  searchLabel: string;
  searchPlaceholder?: string;
  searchValue: string;
  onSearchChange: (value: string) => void;
  children?: ReactNode;
}) {
  const id = useId();

  return (
    <div className="flex flex-wrap items-center gap-md">
      <div className="min-w-0 flex-1">
        <label htmlFor={id} className="sr-only">
          {searchLabel}
        </label>
        <input
          id={id}
          type="search"
          value={searchValue}
          onChange={(e) => onSearchChange(e.target.value)}
          placeholder={searchPlaceholder ?? searchLabel}
          className="w-full rounded-md border border-outline bg-surface-raised px-md py-sm text-body-large text-ink-primary outline-none transition-colors duration-normal ease-standard placeholder:text-ink-secondary focus:border-brand-primary dark:border-outline-dark dark:bg-surface-dark-raised dark:text-ink-dark-primary dark:placeholder:text-ink-dark-secondary"
        />
      </div>
      {children ? <div className="flex flex-wrap items-center gap-sm">{children}</div> : null}
    </div>
  );
}
