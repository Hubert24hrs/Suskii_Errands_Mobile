export function StoreBadges({
  appStoreLabel,
  googlePlayLabel,
  downloadLabel,
}: {
  appStoreLabel: string;
  googlePlayLabel: string;
  downloadLabel: string;
}) {
  return (
    <div className="flex flex-wrap justify-center gap-md" aria-label={downloadLabel}>
      {/* TODO(M7/M9): point at the real App Store listing once published */}
      <a
        href="#"
        className="rounded-md border border-outline bg-surface-raised px-xl py-md text-label-large text-ink-primary transition-colors duration-normal ease-standard hover:bg-surface-muted dark:border-outline-dark dark:bg-surface-dark-raised dark:text-ink-dark-primary dark:hover:bg-surface-dark-muted"
      >
        {appStoreLabel}
      </a>
      {/* TODO(M7/M9): point at the real Google Play listing once published */}
      <a
        href="#"
        className="rounded-md border border-outline bg-surface-raised px-xl py-md text-label-large text-ink-primary transition-colors duration-normal ease-standard hover:bg-surface-muted dark:border-outline-dark dark:bg-surface-dark-raised dark:text-ink-dark-primary dark:hover:bg-surface-dark-muted"
      >
        {googlePlayLabel}
      </a>
    </div>
  );
}
