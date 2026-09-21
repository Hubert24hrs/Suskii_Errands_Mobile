'use client';

import { useState } from 'react';
import { useInfiniteQuery, useQuery, useQueryClient } from '@tanstack/react-query';
import type { Dictionary } from '@/lib/i18n/en';
import { walletRepository } from '@/mocks/repositories';
import { MoneyText } from '@/components/MoneyText';
import { StateBlock } from '@/components/StateBlock';
import { StatusChip } from '@/components/StatusChip';
import { WithdrawalModal } from './WithdrawalModal';
import {
  errorText,
  formatDateTime,
  signedAmountMinor,
  walletKindLabel,
  walletTxnStatusLabel,
  walletTxnStatusTone,
} from './_shared';

const PAGE_SIZE = 20;

export function WalletClient({ dict }: { dict: Dictionary }) {
  const queryClient = useQueryClient();
  const [withdrawOpen, setWithdrawOpen] = useState(false);

  const summaryQuery = useQuery({
    queryKey: ['wallet', 'summary'],
    queryFn: () => walletRepository.getSummary(),
  });
  const txnsQuery = useInfiniteQuery({
    queryKey: ['wallet', 'transactions'],
    queryFn: ({ pageParam }) =>
      walletRepository.getTransactions({ cursor: pageParam, limit: PAGE_SIZE }),
    initialPageParam: undefined as string | undefined,
    getNextPageParam: (lastPage) =>
      lastPage.length === PAGE_SIZE ? lastPage[lastPage.length - 1]?.id : undefined,
  });

  const summary = summaryQuery.data;
  const txns = txnsQuery.data?.pages.flat() ?? [];
  // dict.common.loadMore does not exist yet — raw key fallback (reported).
  const loadMoreLabel = (dict.common as Record<string, string>).loadMore ?? 'loadMore';

  return (
    <div className="mx-auto w-full max-w-5xl px-lg py-xxxl">
      <div className="flex flex-wrap items-center justify-between gap-md">
        <h1 className="text-headline-medium text-ink-primary dark:text-ink-dark-primary">
          {dict.wallet.title}
        </h1>
        <button
          type="button"
          onClick={() => setWithdrawOpen(true)}
          disabled={!summary}
          className="rounded-md bg-brand-primary px-xl py-sm text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong disabled:opacity-50"
        >
          {dict.wallet.withdraw}
        </button>
      </div>

      <div className="mt-xxl">
        {summaryQuery.isPending ? (
          <StateBlock variant="loading" />
        ) : summaryQuery.isError ? (
          <StateBlock
            variant="error"
            errorMessage={errorText(dict, summaryQuery.error)}
            retryLabel={dict.common.retry}
            onRetry={() => void summaryQuery.refetch()}
          />
        ) : summary ? (
          <div className="grid gap-lg sm:grid-cols-2">
            <div className="rounded-lg border border-outline bg-surface-raised p-xl dark:border-outline-dark dark:bg-surface-dark-raised">
              <p className="text-label-large text-ink-secondary dark:text-ink-dark-secondary">
                {dict.wallet.availableBalance}
              </p>
              <MoneyText
                amountMinor={summary.available.amountMinor}
                currency={summary.available.currency}
                className="mt-sm block text-headline-medium text-ink-primary dark:text-ink-dark-primary"
              />
            </div>
            <div className="rounded-lg border border-outline bg-surface-raised p-xl dark:border-outline-dark dark:bg-surface-dark-raised">
              <p className="text-label-large text-ink-secondary dark:text-ink-dark-secondary">
                {dict.wallet.pendingBalance}
              </p>
              <MoneyText
                amountMinor={summary.pending.amountMinor}
                currency={summary.pending.currency}
                className="mt-sm block text-headline-medium text-ink-primary dark:text-ink-dark-primary"
              />
            </div>
          </div>
        ) : null}
      </div>

      <section className="mt-xxl">
        <h2 className="text-title-large text-ink-primary dark:text-ink-dark-primary">
          {dict.wallet.transactionsTitle}
        </h2>
        <div className="mt-lg">
          {txnsQuery.isPending ? (
            <StateBlock variant="loading" />
          ) : txnsQuery.isError ? (
            <StateBlock
              variant="error"
              errorMessage={errorText(dict, txnsQuery.error)}
              retryLabel={dict.common.retry}
              onRetry={() => void txnsQuery.refetch()}
            />
          ) : txns.length === 0 ? (
            <StateBlock variant="empty" emptyTitle={dict.wallet.transactionsEmpty} />
          ) : (
            <>
              <ul className="flex flex-col gap-md">
                {txns.map((txn) => (
                  <li
                    key={txn.id}
                    className="flex flex-wrap items-center justify-between gap-md rounded-lg border border-outline bg-surface-raised p-lg transition-colors duration-normal ease-standard dark:border-outline-dark dark:bg-surface-dark-raised"
                  >
                    <div>
                      <p className="text-body-large text-ink-primary dark:text-ink-dark-primary">
                        {walletKindLabel(dict, txn.kind)}
                      </p>
                      <p className="text-body-small text-ink-secondary dark:text-ink-dark-secondary">
                        {formatDateTime(txn.createdAt)}
                      </p>
                    </div>
                    <div className="flex items-center gap-md">
                      <MoneyText
                        amountMinor={signedAmountMinor(txn)}
                        currency={txn.amount.currency}
                        className="text-title-large text-ink-primary dark:text-ink-dark-primary"
                      />
                      <StatusChip
                        label={walletTxnStatusLabel(dict, txn.status)}
                        tone={walletTxnStatusTone(txn.status)}
                      />
                    </div>
                  </li>
                ))}
              </ul>
              {txnsQuery.hasNextPage ? (
                <button
                  type="button"
                  onClick={() => void txnsQuery.fetchNextPage()}
                  disabled={txnsQuery.isFetchingNextPage}
                  className="mt-lg rounded-md border border-outline px-xl py-sm text-label-large text-ink-primary transition-colors duration-normal ease-standard hover:bg-surface-muted disabled:opacity-50 dark:border-outline-dark dark:text-ink-dark-primary dark:hover:bg-surface-dark-muted"
                >
                  {txnsQuery.isFetchingNextPage ? dict.common.loading : loadMoreLabel}
                </button>
              ) : null}
            </>
          )}
        </div>
      </section>

      {summary ? (
        <WithdrawalModal
          open={withdrawOpen}
          onClose={() => setWithdrawOpen(false)}
          dict={dict}
          currency={summary.available.currency}
          title={dict.wallet.withdrawal.title}
          confirmCta={dict.wallet.withdrawal.confirmCta}
          doneNote={dict.wallet.withdrawal.doneNote}
          onSubmit={(amountMinor, idempotencyKey) =>
            walletRepository.requestWithdrawal(
              { amountMinor, currency: summary.available.currency },
              idempotencyKey,
            )
          }
          onSuccess={() => void queryClient.invalidateQueries({ queryKey: ['wallet'] })}
        />
      ) : null}
    </div>
  );
}
