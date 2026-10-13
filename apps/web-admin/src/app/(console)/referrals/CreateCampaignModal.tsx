'use client';

import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { useQueryClient } from '@tanstack/react-query';
import { dict } from '@/lib/i18n';
import { newIdempotencyKey } from '@/lib/idempotency';
import { referralRepository } from '@/lib/repositories';
import { Modal } from '@/components/Modal';
import { errorText, isSessionError } from '../_shared';
import { COUNTRIES, COUNTRY_CURRENCY, countryLabel } from './_shared';

const inputClass =
  'w-full rounded-md border border-outline bg-surface px-md py-sm text-body-large text-ink-primary outline-none transition-colors duration-normal ease-standard focus:border-brand-primary dark:border-outline-dark dark:bg-surface-dark dark:text-ink-dark-primary';
const labelClass = 'text-label-large text-ink-primary dark:text-ink-dark-primary';

// A real <label>, so the text names its control for screen readers.
function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <label className="flex flex-col gap-xs">
      <span className={labelClass}>{label}</span>
      {children}
    </label>
  );
}

/**
 * The budget is entered as integer minor units (kobo, cents) — the currency
 * code follows the selected country and is display-only here.
 */
function MinorUnitsInput({
  value,
  onChange,
  currency,
}: {
  value: string;
  onChange: (value: string) => void;
  currency: string;
}) {
  return (
    <div className="flex items-center gap-sm">
      <input
        type="number"
        min={0}
        step={1}
        inputMode="numeric"
        value={value}
        onChange={(e) => onChange(e.target.value)}
        className={inputClass}
        aria-label={dict.referrals.campaign.budgetLabel}
      />
      <span className="text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
        {currency}
      </span>
    </div>
  );
}

export function CreateCampaignModal({
  open,
  onClose,
  onCreated,
}: {
  open: boolean;
  onClose: () => void;
  /** Called after a successful create (the screen says whether it awaits approval). */
  onCreated?: () => void;
}) {
  const router = useRouter();
  const queryClient = useQueryClient();

  const [name, setName] = useState('');
  const [country, setCountry] = useState(COUNTRIES[0]);
  // A referral campaign is a share of the platform's commission (OD-01), with a budget.
  const [ratePercent, setRatePercent] = useState('');
  const [budget, setBudget] = useState('');
  const [startsAt, setStartsAt] = useState('');
  const [endsAt, setEndsAt] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // One key per create intent: reset when the form opens and after success;
  // reused while the same filled-in form is retried.
  const [createKey, setCreateKey] = useState(() => newIdempotencyKey());

  const reset = () => {
    setName('');
    setCountry(COUNTRIES[0]);
    setRatePercent('');
    setBudget('');
    setStartsAt('');
    setEndsAt('');
    setError(null);
    setCreateKey(newIdempotencyKey());
  };

  // A (re)opened form is a fresh create intent.
  useEffect(() => {
    if (open) reset();
  }, [open]);

  const currency = COUNTRY_CURRENCY[country];
  // Whole or decimal percent → basis points; the server stores bps.
  const rateBps = Math.round(Number.parseFloat(ratePercent) * 100);
  const budgetMinor = budget === '' ? undefined : Number.parseInt(budget, 10);
  const valid =
    name.trim() !== '' &&
    Number.isInteger(rateBps) &&
    rateBps > 0 &&
    rateBps <= 10_000 &&
    (budgetMinor === undefined || (Number.isInteger(budgetMinor) && budgetMinor > 0)) &&
    startsAt !== '';

  const submit = async () => {
    if (!valid || busy) return;
    setBusy(true);
    setError(null);
    try {
      await referralRepository.createCampaign(
        {
          name: name.trim(),
          country,
          rateBps,
          budget: budgetMinor === undefined ? undefined : { amountMinor: budgetMinor, currency },
          startsAt: new Date(startsAt),
          endsAt: endsAt ? new Date(endsAt) : undefined,
        },
        createKey,
      );
      setCreateKey(newIdempotencyKey());
      void queryClient.invalidateQueries({ queryKey: ['referrals'] });
      onCreated?.();
      onClose();
    } catch (e) {
      if (isSessionError(e)) {
        router.replace('/sign-in');
      } else {
        setError(errorText(e));
      }
    } finally {
      setBusy(false);
    }
  };

  return (
    <Modal
      open={open}
      onClose={onClose}
      title={dict.referrals.campaign.createCta}
      closeLabel={dict.common.close}
    >
      <form
        className="flex flex-col gap-lg"
        onSubmit={(e) => {
          e.preventDefault();
          void submit();
        }}
      >
        <Field label={dict.referrals.campaign.nameLabel}>
          <input
            type="text"
            value={name}
            onChange={(e) => setName(e.target.value)}
            className={inputClass}
          />
        </Field>
        <Field label={dict.directory.columns.country}>
          <select
            value={country}
            onChange={(e) => setCountry(e.target.value)}
            className={inputClass}
          >
            {COUNTRIES.map((c) => (
              <option key={c} value={c}>
                {countryLabel(c)}
              </option>
            ))}
          </select>
        </Field>
        <Field label={dict.referrals.campaign.rateLabel}>
          <input
            type="number"
            min={0.01}
            max={100}
            step={0.01}
            inputMode="decimal"
            value={ratePercent}
            onChange={(e) => setRatePercent(e.target.value)}
            className={inputClass}
          />
        </Field>
        <Field label={dict.referrals.campaign.budgetLabel}>
          <MinorUnitsInput value={budget} onChange={setBudget} currency={currency} />
        </Field>
        <Field label={dict.common.fromDate}>
          <input
            type="date"
            value={startsAt}
            onChange={(e) => setStartsAt(e.target.value)}
            className={inputClass}
          />
        </Field>
        <Field label={dict.common.toDate}>
          <input
            type="date"
            value={endsAt}
            onChange={(e) => setEndsAt(e.target.value)}
            className={inputClass}
          />
        </Field>
        {error ? (
          <p role="alert" className="text-body-small text-error dark:text-error-dark">
            {error}
          </p>
        ) : null}
        <div className="flex gap-md">
          <button
            type="submit"
            disabled={!valid || busy}
            className="rounded-md bg-brand-primary px-xl py-sm text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong disabled:opacity-50"
          >
            {dict.common.submit}
          </button>
          <button
            type="button"
            onClick={onClose}
            className="rounded-md border border-outline px-lg py-sm text-label-large text-ink-primary transition-colors duration-normal ease-standard hover:bg-surface-muted dark:border-outline-dark dark:text-ink-dark-primary dark:hover:bg-surface-dark-muted"
          >
            {dict.common.cancel}
          </button>
        </div>
      </form>
    </Modal>
  );
}
