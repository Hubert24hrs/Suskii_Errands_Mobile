import type { Metadata } from 'next';
import { getDictionary, isLocale, type Locale } from '@/lib/i18n';
import { Container } from '@/components/Container';
import { privacyPolicy, type PolicyBlock } from '@/content/privacy-policy';

type Props = { params: Promise<{ locale: string }> };

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const { locale } = await params;
  if (!isLocale(locale)) return {};
  const dict = await getDictionary(locale);
  return { title: dict.legal.privacyTitle };
}

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

/** The published policy (src/content/privacy-policy.ts); English for every locale. */
export default async function PrivacyPage({ params }: Props) {
  const { locale } = await params;
  const dict = await getDictionary(locale as Locale);

  return (
    <Container className="max-w-3xl py-xxxl">
      <h1 className="text-display-small text-ink-primary dark:text-ink-dark-primary">
        {dict.legal.privacyTitle}
      </h1>
      <p className="mt-md text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
        Last updated {privacyPolicy.updated}
      </p>
      {privacyPolicy.sections.map((section) => (
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
