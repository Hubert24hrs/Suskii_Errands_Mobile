import { Container } from './Container';

export function FaqAccordion({ items }: { items: readonly { q: string; a: string }[] }) {
  return (
    <Container className="max-w-3xl py-xxxl">
      <div className="space-y-md">
        {items.map((item) => (
          <details
            key={item.q}
            className="group rounded-lg border border-outline bg-surface-raised p-lg dark:border-outline-dark dark:bg-surface-dark-raised"
          >
            <summary className="cursor-pointer list-none text-title-medium text-ink-primary marker:hidden dark:text-ink-dark-primary [&::-webkit-details-marker]:hidden">
              {item.q}
              <span
                aria-hidden="true"
                className="float-right text-brand-primary transition-transform duration-normal ease-standard group-open:rotate-45 dark:text-brand-secondary"
              >
                +
              </span>
            </summary>
            <p className="mt-md text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
              {item.a}
            </p>
          </details>
        ))}
      </div>
    </Container>
  );
}
