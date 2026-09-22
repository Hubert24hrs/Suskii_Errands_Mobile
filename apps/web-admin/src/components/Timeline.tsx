type StepState = 'done' | 'current' | 'pending';

const dotClasses: Record<StepState, string> = {
  done: 'bg-success dark:bg-success-dark',
  current: 'bg-brand-primary',
  pending: 'bg-outline dark:bg-outline-dark',
};

const labelClasses: Record<StepState, string> = {
  done: 'text-ink-primary dark:text-ink-dark-primary',
  current: 'font-semibold text-ink-primary dark:text-ink-dark-primary',
  pending: 'text-ink-secondary dark:text-ink-dark-secondary',
};

export function Timeline({
  steps,
}: {
  steps: { label: string; state: StepState; timestamp?: string }[];
}) {
  return (
    <ol className="flex flex-col">
      {steps.map((step, i) => (
        <li key={`${step.label}-${i}`} className="flex gap-md">
          <div className="flex flex-col items-center">
            <span
              aria-hidden="true"
              className={`mt-xs h-3 w-3 shrink-0 rounded-pill ${dotClasses[step.state]}`}
            />
            {i < steps.length - 1 ? (
              <span
                aria-hidden="true"
                className="w-px flex-1 bg-outline dark:bg-outline-dark"
              />
            ) : null}
          </div>
          <div className={i < steps.length - 1 ? 'pb-lg' : ''}>
            <p className={`text-body-medium ${labelClasses[step.state]}`}>{step.label}</p>
            {step.timestamp ? (
              <p className="text-body-small text-ink-secondary dark:text-ink-dark-secondary">
                {step.timestamp}
              </p>
            ) : null}
          </div>
        </li>
      ))}
    </ol>
  );
}
