import { Container } from '@/components/Container';
import type { PolicyBlock, PolicySection } from '@/content/privacy-policy';

const bodyText = 'text-body-large text-ink-secondary dark:text-ink-dark-secondary';
const cellBorder = 'border-b border-outline dark:border-outline-dark';

function Block({ block }: { block: PolicyBlock }) {
  switch (block.kind) {
    case 'p':
      return <p className={`mt-md ${bodyText}`}>{block.text}</p>;
    case 'list': {
      const List = block.ordered ? 'ol' : 'ul';
      return (
        <List className={`mt-md space-y-sm pl-lg ${block.ordered ? 'list-decimal' : 'list-disc'} ${bodyText}`}>
          {block.items.map((item) => (
            <li key={item}>{item}</li>
          ))}
        </List>
      );
    }
    case 'table':
      return (
        <div className="mt-md overflow-x-auto">
          <table className="w-full min-w-[36rem] border-collapse text-left text-body-medium">
            <thead>
              <tr>
                {block.head.map((h) => (
                  <th
                    key={h}
                    scope="col"
                    className={`${cellBorder} py-sm pr-md align-bottom font-semibold text-ink-primary dark:text-ink-dark-primary`}
                  >
                    {h}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody className="text-ink-secondary dark:text-ink-dark-secondary">
              {block.rows.map((row) => (
                <tr key={row[0]}>
                  {row.map((cell, i) => (
                    <td key={i} className={`${cellBorder} py-sm pr-md align-top`}>
                      {cell}
                    </td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      );
  }
}

/** A published legal document (privacy policy, terms): title, date and sections. */
export function PolicyDocument({
  title,
  updated,
  sections,
}: {
  title: string;
  updated: string;
  sections: PolicySection[];
}) {
  return (
    <Container className="max-w-3xl py-xxxl">
      <h1 className="text-display-small text-ink-primary dark:text-ink-dark-primary">{title}</h1>
      <p className="mt-md text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
        Last updated {updated}
      </p>
      {sections.map((section) => (
        <section key={section.heading} className="mt-xl">
          <h2 className="text-headline-small text-ink-primary dark:text-ink-dark-primary">
            {section.heading}
          </h2>
          {section.blocks.map((block, i) => (
            <Block key={i} block={block} />
          ))}
        </section>
      ))}
    </Container>
  );
}
