'use client';

import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { useQueryClient } from '@tanstack/react-query';
import { dict } from '@/lib/i18n';
import { newIdempotencyKey } from '@/lib/idempotency';
import { referralRepository } from '@/mocks/repositories';
import { Modal } from '@/components/Modal';
import { errorText, isSessionError } from '../_shared';
import { COUNTRIES, COUNTRY_CURRENCY, countryLabel } from './_shared';

const inputClass =
  'w-full rounded-md border border-outline bg-surface px-md py-sm text-body-large text-ink-primary outline-none transition-colors duration-normal ease-standard focus:border-brand-primary dark:border-outline-dark dark:bg-surface-dark dark:text-ink-dark-primary';
const labelClass = 'text-label-large text-ink-primary dark:text-ink-dark-primary';

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="flex flex-col gap-xs">
      <span className={labelClass}>{label}</span>
      {children}
    </div>
  );
}

/**
 * Reward amounts are entered as integer minor units (kobo, cents) — the
 * currency code follows the selected country and is display-only here.
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
        aria-label={dict.referrals.campaign.rewardAmountLabel}
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
}: {
  open: boolean;
  onClose: () => void;
}) {
  const router = useRouter();
  const queryClient = useQueryClient();

  const [name, setName] = useState('');
  const [country, setCountry] = useState(COUNTRIES[0]);
  const [referrerReward, setReferrerReward] = useState('');
  const [refereeReward, setRefereeReward] = useState('');
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
    setReferrerReward('');
    setRefereeReward('');
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
  const referrerMinor = Number.parseInt(referrerReward, 10);
  const refereeMinor = Number.parseInt(refereeReward, 10);
  const valid =
    name.trim() !== '' &&
    Number.isInteger(referrerMinor) &&
    referrerMinor >= 0 &&
    Number.isInteger(refereeMinor) &&
    refereeMinor >= 0 &&
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
          referrerReward: { amountMinor: referrerMinor, currency },
          refereeReward: { amountMinor: refereeMinor, currency },
          startsAt: new Date(startsAt),
          endsAt: endsAt ? new Date(endsAt) : undefined,
        },
        createKey,
      );
      setCreateKey(newIdempotencyKey());
      void queryClient.invalidateQueries({ queryKey: ['referrals'] });
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
        <Field label={`${dict.referrals.columns.referrer} — ${dict.referrals.campaign.rewardAmountLabel}`}>
          <MinorUnitsInput value={referrerReward} onChange={setReferrerReward} currency={currency} />
        </Field>
        <Field label={`${dict.referrals.columns.referee} — ${dict.referrals.campaign.rewardAmountLabel}`}>
          <MinorUnitsInput value={refereeReward} onChange={setRefereeReward} currency={currency} />
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
