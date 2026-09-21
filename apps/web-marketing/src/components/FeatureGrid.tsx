import { Container } from './Container';

export type Feature = { title: string; body: string };

export function FeatureGrid({
  title,
  subtitle,
  items,
  columns = 3,
}: {
  title?: string;
  subtitle?: string;
  items: readonly Feature[];
  columns?: 2 | 3;
}) {
  return (
    <section className="bg-surface dark:bg-surface-dark">
      <Container className="py-xxxl">
        {title ? (
          <h2 className="text-headline-medium text-ink-primary dark:text-ink-dark-primary">{title}</h2>
        ) : null}
        {subtitle ? (
          <p className="mt-md max-w-2xl text-body-large text-ink-secondary dark:text-ink-dark-secondary">
            {subtitle}
          </p>
        ) : null}
        <div
          className={`mt-xxl grid gap-xl sm:grid-cols-2 ${columns === 3 ? 'lg:grid-cols-3' : ''}`}
        >
          {items.map((item) => (
            <article
              key={item.title}
              className="rounded-lg border border-outline bg-surface-raised p-xl dark:border-outline-dark dark:bg-surface-dark-raised"
            >
              <h3 className="text-title-large text-ink-primary dark:text-ink-dark-primary">
                {item.title}
              </h3>
              <p className="mt-sm text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
                {item.body}
              </p>
            </article>
          ))}
        </div>
      </Container>
    </section>
  );
}
