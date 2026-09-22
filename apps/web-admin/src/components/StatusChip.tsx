type Tone = 'neutral' | 'info' | 'success' | 'warning' | 'error';

const toneClasses: Record<Tone, string> = {
  neutral:
    'bg-surface-muted text-ink-secondary dark:bg-surface-dark-muted dark:text-ink-dark-secondary',
  info: 'bg-info/10 text-info dark:bg-info-dark/20 dark:text-info-dark',
  success: 'bg-success/10 text-success dark:bg-success-dark/20 dark:text-success-dark',
  warning: 'bg-warning/10 text-warning dark:bg-warning-dark/20 dark:text-warning-dark',
  error: 'bg-error/10 text-error dark:bg-error-dark/20 dark:text-error-dark',
};

export function StatusChip({ label, tone }: { label: string; tone: Tone }) {
  return (
    <span
      className={`inline-flex items-center rounded-pill px-sm py-xs text-label-small ${toneClasses[tone]}`}
    >
      {label}
    </span>
  );
}
