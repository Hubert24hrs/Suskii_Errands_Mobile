'use client';

import { useId, useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import type { Dictionary } from '@/lib/i18n/en';
import { promoRepository } from '@/mocks/repositories';
import type { Promo } from '@/mocks/types';
import { newIdempotencyKey } from '@/lib/idempotency';
import { MoneyText } from '@/components/MoneyText';
import { StateBlock } from '@/components/StateBlock';
import { StatusChip } from '@/components/StatusChip';
import { errorText, formatDate } from '../wallet/_shared';

type ChipTone = 'neutral' | 'info' | 'success' | 'warning' | 'error';

/** Promo badge: applied / expired / active. */
function promoBadge(dict: Dictionary, promo: Promo): { label: string; tone: ChipTone } | null {
  if (promo.redeemed) return { label: dict.promos.badges.applied, tone: 'success' };
  if (promo.expiresAt.getTime() < Date.now()) {
    return { label: dict.promos.badges.expired, tone: 'neutral' };
  }
  return { label: dict.promos.badges.active, tone: 'info' };
}

function campaignText(dict: Dictionary, key: string): string {
  const table = dict.promos.campaigns as Record<string, string>;
  return table[key] ?? key;
}

function PromoCard({ dict, promo }: { dict: Dictionary; promo: Promo }) {
  const badge = promoBadge(dict, promo);
  return (
    <li className="rounded-lg border border-outline bg-surface-raised p-xl transition-colors duration-normal ease-standard dark:border-outline-dark dark:bg-surface-dark-raised">
      <div className="flex flex-wrap items-start justify-between gap-md">
        <div>
          {/* The server sends localization keys; copy resolves through
              dict.promos.campaigns. */}
          <p className="text-title-large text-ink-primary dark:text-ink-dark-primary">
            {campaignText(dict, promo.titleKey)}
          </p>
          <p className="mt-xs text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
            {campaignText(dict, promo.descriptionKey)}
          </p>
        </div>
        {badge ? <StatusChip label={badge.label} tone={badge.tone} /> : null}
      </div>
      <div className="mt-md flex flex-wrap items-center justify-between gap-md">
        <span className="text-headline-medium text-brand-primary dark:text-brand-secondary">
          {promo.percentOff}%
        </span>
        <span className="text-label-large text-ink-secondary dark:text-ink-dark-secondary">
          {promo.code}
        </span>
      </div>
      <div className="mt-md flex flex-wrap items-center justify-between gap-md text-body-small text-ink-secondary dark:text-ink-dark-secondary">
        <span>{formatDate(promo.expiresAt)}</span>
        {promo.maxDiscount ? (
          <MoneyText
            amountMinor={promo.maxDiscount.amountMinor}
            currency={promo.maxDiscount.currency}
          />
        ) : null}
      </div>
    </li>
  );
}

export function PromosClient({ dict }: { dict: Dictionary }) {
  const queryClient = useQueryClient();
  const codeInputId = useId();
  const [code, setCode] = useState('');
  const [idempotencyKey, setIdempotencyKey] = useState(() => newIdempotencyKey());

  const promosQuery = useQuery({
    queryKey: ['promos'],
    queryFn: () => promoRepository.getPromos(),
  });

  const redeem = useMutation({
    mutationFn: () => promoRepository.redeemPromo(code, idempotencyKey),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ['promos'] });
      setCode('');
      setIdempotencyKey(newIdempotencyKey());
    },
  });

  const handleCodeChange = (value: string) => {
    setCode(value);
    // A changed code is a new intent — the old key must not be reused.
    setIdempotencyKey(newIdempotencyKey());
    redeem.reset();
  };

  const promos = promosQuery.data ?? [];

  return (
    <div className="mx-auto w-full max-w-5xl px-lg py-xxxl">
      <h1 className="text-headline-medium text-ink-primary dark:text-ink-dark-primary">
        {dict.promos.title}
      </h1>

      <form
        onSubmit={(e) => {
          e.preventDefault();
          redeem.mutate();
        }}
        className="mt-xxl rounded-lg border border-outline bg-surface-raised p-xl dark:border-outline-dark dark:bg-surface-dark-raised"
      >
        <label
          htmlFor={codeInputId}
          className="text-label-large text-ink-primary dark:text-ink-dark-primary"
        >
          {dict.promos.redeemLabel}
        </label>
        <div className="mt-sm flex flex-wrap gap-md">
          <input
            id={codeInputId}
            type="text"
            value={code}
            onChange={(e) => handleCodeChange(e.target.value)}
            placeholder={dict.promos.redeemPlaceholder}
            autoComplete="off"
            className="min-w-0 flex-1 rounded-md border border-outline bg-surface px-md py-sm text-body-large text-ink-primary outline-none transition-colors duration-normal ease-standard placeholder:text-ink-secondary focus:border-brand-primary dark:border-outline-dark dark:bg-surface-dark dark:text-ink-dark-primary dark:placeholder:text-ink-dark-secondary"
          />
          <button
            type="submit"
            disabled={code.trim() === '' || redeem.isPending}
            className="rounded-md bg-brand-primary px-xl py-sm text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong disabled:opacity-50"
          >
            {redeem.isPending ? dict.common.loading : dict.promos.redeemCta}
          </button>
        </div>
        {redeem.isError ? (
          <p className="mt-sm text-body-small text-error dark:text-error-dark" role="alert">
            {errorText(dict, redeem.error)}
          </p>
        ) : null}
        {redeem.isSuccess ? (
          <p className="mt-sm text-body-small text-success dark:text-success-dark" role="status">
            {dict.promos.redeemedNote}
          </p>
        ) : null}
      </form>

      <div className="mt-xxl">
        {promosQuery.isPending ? (
          <StateBlock variant="loading" />
        ) : promosQuery.isError ? (
          <StateBlock
            variant="error"
            errorMessage={errorText(dict, promosQuery.error)}
            retryLabel={dict.common.retry}
            onRetry={() => void promosQuery.refetch()}
          />
        ) : promos.length === 0 ? (
          <StateBlock variant="empty" emptyTitle={dict.promos.empty} />
        ) : (
          <ul className="flex flex-col gap-lg">
            {promos.map((promo) => (
              <PromoCard key={promo.code} dict={dict} promo={promo} />
            ))}
          </ul>
        )}
      </div>
    </div>
  );
}
