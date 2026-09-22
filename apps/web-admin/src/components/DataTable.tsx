import type { ReactNode } from 'react';
import { StateBlock } from './StateBlock';

export type Column<T> = {
  key: string;
  label: string;
  render?: (row: T) => ReactNode;
  className?: string;
};

export function DataTable<T>({
  columns,
  rows,
  keyOf,
  emptyTitle,
  emptyBody,
  onRowClick,
}: {
  columns: Column<T>[];
  rows: T[];
  keyOf: (row: T) => string;
  emptyTitle?: string;
  emptyBody?: string;
  onRowClick?: (row: T) => void;
}) {
  if (rows.length === 0) {
    return <StateBlock variant="empty" emptyTitle={emptyTitle} emptyBody={emptyBody} />;
  }

  return (
    <div className="overflow-x-auto rounded-lg border border-outline dark:border-outline-dark">
      <table className="w-full border-collapse text-left text-body-medium">
        <thead>
          <tr className="border-b border-outline bg-surface-muted dark:border-outline-dark dark:bg-surface-dark-muted">
            {columns.map((col) => (
              <th
                key={col.key}
                scope="col"
                className={`px-md py-sm text-label-large text-ink-secondary dark:text-ink-dark-secondary ${col.className ?? ''}`}
              >
                {col.label}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map((row) => (
            <tr
              key={keyOf(row)}
              onClick={onRowClick ? () => onRowClick(row) : undefined}
              className={`border-b border-outline bg-surface-raised last:border-b-0 dark:border-outline-dark dark:bg-surface-dark-raised ${
                onRowClick
                  ? 'cursor-pointer transition-colors duration-normal ease-standard hover:bg-surface-muted dark:hover:bg-surface-dark-muted'
                  : ''
              }`}
            >
              {columns.map((col) => (
                <td
                  key={col.key}
                  className={`px-md py-md text-ink-primary dark:text-ink-dark-primary ${col.className ?? ''}`}
                >
                  {col.render
                    ? col.render(row)
                    : String((row as Record<string, unknown>)[col.key] ?? '')}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
