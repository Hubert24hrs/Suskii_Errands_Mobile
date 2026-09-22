type Tone = 'neutral' | 'success' | 'warning' | 'error';

const deltaClasses: Record<Tone, string> = {
  neutral: 'text-ink-secondary dark:text-ink-dark-secondary',
  success: 'text-success dark:text-success-dark',
  warning: 'text-warning dark:text-warning-dark',
  error: 'text-error dark:text-error-dark',
};

export function KpiCard({
  label,
  value,
  delta,
  tone = 'neutral',
}: {
  label: string;
  value: string;
  delta?: string;
  tone?: Tone;
}) {
  return (
    <div className="rounded-lg border border-outline bg-surface-raised p-xl dark:border-outline-dark dark:bg-surface-dark-raised">
      <p className="text-label-large text-ink-secondary dark:text-ink-dark-secondary">{label}</p>
      <p className="mt-sm text-headline-medium text-ink-primary dark:text-ink-dark-primary">
        {value}
      </p>
      {delta ? <p className={`mt-xs text-body-small ${deltaClasses[tone]}`}>{delta}</p> : null}
    </div>
  );
}
