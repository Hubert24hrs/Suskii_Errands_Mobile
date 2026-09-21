'use client';

import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import type { Dictionary } from '@/lib/i18n/en';
import { referralRepository } from '@/mocks/repositories';
import { CopyButton } from '@/components/CopyButton';
import { MoneyText } from '@/components/MoneyText';
import { StateBlock } from '@/components/StateBlock';
import { WithdrawalModal } from '../wallet/WithdrawalModal';
import { errorText } from '../wallet/_shared';

export function ReferralsClient({ dict }: { dict: Dictionary }) {
  const queryClient = useQueryClient();
  const [withdrawOpen, setWithdrawOpen] = useState(false);

  const summaryQuery = useQuery({
    queryKey: ['referrals', 'summary'],
    queryFn: () => referralRepository.getSummary(),
  });
  const summary = summaryQuery.data;

  return (
    <div className="mx-auto w-full max-w-5xl px-lg py-xxxl">
      <h1 className="text-headline-medium text-ink-primary dark:text-ink-dark-primary">
        {dict.referrals.title}
      </h1>

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
          <>
            <div className="grid gap-lg sm:grid-cols-2">
              <div className="rounded-lg border border-outline bg-surface-raised p-xl dark:border-outline-dark dark:bg-surface-dark-raised">
                <p className="text-label-large text-ink-secondary dark:text-ink-dark-secondary">
                  {dict.referrals.codeLabel}
                </p>
                <div className="mt-md flex flex-wrap items-center justify-between gap-md">
                  <span className="text-title-large text-ink-primary dark:text-ink-dark-primary">
                    {summary.code}
                  </span>
                  <CopyButton
                    text={summary.code}
                    label={dict.referrals.copy}
                    copiedLabel={dict.referrals.copied}
                  />
                </div>
              </div>
              <div className="rounded-lg border border-outline bg-surface-raised p-xl dark:border-outline-dark dark:bg-surface-dark-raised">
                <p className="text-label-large text-ink-secondary dark:text-ink-dark-secondary">
                  {dict.referrals.shareLink}
                </p>
                <div className="mt-md flex flex-wrap items-center justify-between gap-md">
                  <span className="break-all text-body-medium text-ink-primary dark:text-ink-dark-primary">
                    {summary.shareLink}
                  </span>
                  <CopyButton
                    text={summary.shareLink}
                    label={dict.referrals.copy}
                    copiedLabel={dict.referrals.copied}
                  />
                </div>
              </div>
            </div>

            <div className="mt-xxl grid gap-lg sm:grid-cols-3">
              <div className="rounded-lg border border-outline bg-surface-raised p-xl dark:border-outline-dark dark:bg-surface-dark-raised">
                <p className="text-label-large text-ink-secondary dark:text-ink-dark-secondary">
                  {dict.referrals.stats.invited}
                </p>
                <p className="mt-sm text-headline-medium text-ink-primary dark:text-ink-dark-primary">
                  {summary.invitedCount}
                </p>
              </div>
              <div className="rounded-lg border border-outline bg-surface-raised p-xl dark:border-outline-dark dark:bg-surface-dark-raised">
                <p className="text-label-large text-ink-secondary dark:text-ink-dark-secondary">
                  {dict.referrals.stats.joined}
                </p>
                <p className="mt-sm text-headline-medium text-ink-primary dark:text-ink-dark-primary">
                  {summary.activeReferrals}
                </p>
              </div>
              <div className="rounded-lg border border-outline bg-surface-raised p-xl dark:border-outline-dark dark:bg-surface-dark-raised">
                <p className="text-label-large text-ink-secondary dark:text-ink-dark-secondary">
                  {dict.referrals.stats.earned}
                </p>
                <MoneyText
                  amountMinor={summary.earnedTotal.amountMinor}
                  currency={summary.earnedTotal.currency}
                  className="mt-sm block text-headline-medium text-ink-primary dark:text-ink-dark-primary"
                />
              </div>
            </div>

            <div className="mt-xxl flex flex-wrap items-center justify-between gap-md rounded-lg border border-outline bg-surface-raised p-xl dark:border-outline-dark dark:bg-surface-dark-raised">
              <div>
                <p className="text-label-large text-ink-secondary dark:text-ink-dark-secondary">
                  {dict.wallet.availableBalance}
                </p>
                <MoneyText
                  amountMinor={summary.available.amountMinor}
                  currency={summary.available.currency}
                  className="mt-sm block text-title-large text-ink-primary dark:text-ink-dark-primary"
                />
                <p className="mt-sm text-body-small text-ink-secondary dark:text-ink-dark-secondary">
                  {dict.wallet.pendingBalance}{' '}
                  <MoneyText
                    amountMinor={summary.holding.amountMinor}
                    currency={summary.holding.currency}
                  />
                </p>
              </div>
              <button
                type="button"
                onClick={() => setWithdrawOpen(true)}
                disabled={summary.available.amountMinor <= 0}
                className="rounded-md bg-brand-primary px-xl py-sm text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong disabled:opacity-50"
              >
                {dict.referrals.withdrawCta}
              </button>
            </div>

            {summary.invitedCount === 0 ? (
              <StateBlock variant="empty" emptyTitle={dict.referrals.empty} />
            ) : null}

            <WithdrawalModal
              open={withdrawOpen}
              onClose={() => setWithdrawOpen(false)}
              dict={dict}
              currency={summary.available.currency}
              title={dict.referrals.withdrawCta}
              confirmCta={dict.wallet.withdrawal.confirmCta}
              doneNote={dict.wallet.withdrawal.doneNote}
              onSubmit={(amountMinor, idempotencyKey) =>
                referralRepository.requestWithdrawal(
                  { amountMinor, currency: summary.available.currency },
                  idempotencyKey,
                )
              }
              onSuccess={() =>
                void queryClient.invalidateQueries({ queryKey: ['referrals'] })
              }
            />
          </>
        ) : null}
      </div>
    </div>
  );
}
