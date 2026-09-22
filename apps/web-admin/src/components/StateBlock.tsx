export function StateBlock({
  variant,
  errorMessage,
  retryLabel,
  onRetry,
  emptyTitle,
  emptyBody,
}: {
  variant: 'loading' | 'error' | 'empty';
  errorMessage?: string;
  retryLabel?: string;
  onRetry?: () => void;
  emptyTitle?: string;
  emptyBody?: string;
}) {
  if (variant === 'loading') {
    return (
      <div className="flex w-full flex-col gap-md" aria-busy="true">
        <div className="h-5 w-2/5 animate-pulse rounded-sm bg-surface-muted dark:bg-surface-dark-muted" />
        <div className="h-4 w-full animate-pulse rounded-sm bg-surface-muted dark:bg-surface-dark-muted" />
        <div className="h-4 w-4/5 animate-pulse rounded-sm bg-surface-muted dark:bg-surface-dark-muted" />
      </div>
    );
  }

  if (variant === 'error') {
    return (
      <div className="flex w-full flex-col items-center gap-md py-xxl text-center">
        <p className="text-body-large text-error dark:text-error-dark">{errorMessage}</p>
        {onRetry && retryLabel ? (
          <button
            type="button"
            onClick={onRetry}
            className="rounded-md bg-brand-primary px-xl py-sm text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong"
          >
            {retryLabel}
          </button>
        ) : null}
      </div>
    );
  }

  return (
    <div className="flex w-full flex-col items-center gap-sm py-xxl text-center">
      <p className="text-title-large text-ink-primary dark:text-ink-dark-primary">{emptyTitle}</p>
      {emptyBody ? (
        <p className="text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
          {emptyBody}
        </p>
      ) : null}
    </div>
  );
}
