'use client';

import Link from 'next/link';
import { useQuery } from '@tanstack/react-query';
import type { Dictionary } from '@/lib/i18n/en';
import type { Locale } from '@/lib/i18n';
import { catalogRepository, requestRepository } from '@/mocks/repositories';
import type { JobRequest } from '@/mocks/types';
import { MoneyText } from '@/components/MoneyText';
import { StateBlock } from '@/components/StateBlock';
import { StatusChip } from '@/components/StatusChip';
import {
  categoryLabel,
  errorText,
  formatDateTime,
  statusLabel,
  statusTone,
} from './_shared';

function RequestCard({
  request,
  locale,
  dict,
  categories,
}: {
  request: JobRequest;
  locale: Locale;
  dict: Dictionary;
  categories: Awaited<ReturnType<typeof catalogRepository.getCategories>>;
}) {
  return (
    <Link
      href={`/${locale}/requests/${request.id}`}
      className="block rounded-lg border border-outline bg-surface-raised p-xl transition-colors duration-normal ease-standard hover:border-brand-primary dark:border-outline-dark dark:bg-surface-dark-raised dark:hover:border-brand-secondary"
    >
      <div className="flex flex-wrap items-center justify-between gap-md">
        <span className="text-label-large text-ink-secondary dark:text-ink-dark-secondary">
          {categoryLabel(dict, categories, request.categoryId)}
        </span>
        <StatusChip label={statusLabel(dict, request.status)} tone={statusTone(request.status)} />
      </div>
      <p className="mt-sm line-clamp-2 text-body-large text-ink-primary dark:text-ink-dark-primary">
        {request.description}
      </p>
      <div className="mt-md flex flex-wrap items-center justify-between gap-md">
        {request.preferredPrice ? (
          <MoneyText
            amountMinor={request.preferredPrice.amountMinor}
            currency={request.preferredPrice.currency}
            className="text-title-large text-ink-primary dark:text-ink-dark-primary"
          />
        ) : (
          <span />
        )}
        <span className="text-body-small text-ink-secondary dark:text-ink-dark-secondary">
          {formatDateTime(request.createdAt)}
        </span>
      </div>
    </Link>
  );
}

export function RequestsListClient({ locale, dict }: { locale: Locale; dict: Dictionary }) {
  // Active and history are merged into one newest-first list — the dict has
  // no separate section headings yet.
  const query = useQuery({
    queryKey: ['requests', 'mine'],
    queryFn: async () => {
      const [active, history] = await Promise.all([
        requestRepository.getMyActiveJobs(),
        requestRepository.getMyRequestHistory({ limit: 50 }),
      ]);
      return [...active, ...history];
    },
  });
  const categoriesQuery = useQuery({
    queryKey: ['catalog', 'categories'],
    queryFn: () => catalogRepository.getCategories(),
  });

  const requests = query.data;
  const categories = categoriesQuery.data ?? [];

  return (
    <div className="mx-auto w-full max-w-5xl px-lg py-xxxl">
      <div className="flex flex-wrap items-center justify-between gap-md">
        <h1 className="text-headline-medium text-ink-primary dark:text-ink-dark-primary">
          {dict.requests.listTitle}
        </h1>
        <Link
          href={`/${locale}/requests/new`}
          className="rounded-md bg-brand-primary px-xl py-sm text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong"
        >
          {dict.requests.newRequestCta}
        </Link>
      </div>

      <div className="mt-xxl">
        {query.isPending ? (
          <StateBlock variant="loading" />
        ) : query.isError ? (
          <StateBlock
            variant="error"
            errorMessage={errorText(dict, query.error)}
            retryLabel={dict.common.retry}
            onRetry={() => void query.refetch()}
          />
        ) : (requests ?? []).length === 0 ? (
          <div className="flex flex-col items-center">
            <StateBlock
              variant="empty"
              emptyTitle={dict.requests.listEmptyTitle}
              emptyBody={dict.requests.listEmptyBody}
            />
            <Link
              href={`/${locale}/requests/new`}
              className="rounded-md bg-brand-primary px-xl py-sm text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong"
            >
              {dict.requests.newRequestCta}
            </Link>
          </div>
        ) : (
          <ul className="flex flex-col gap-lg">
            {(requests ?? []).map((request) => (
              <li key={request.id}>
                <RequestCard
                  request={request}
                  locale={locale}
                  dict={dict}
                  categories={categories}
                />
              </li>
            ))}
          </ul>
        )}
      </div>
    </div>
  );
}
