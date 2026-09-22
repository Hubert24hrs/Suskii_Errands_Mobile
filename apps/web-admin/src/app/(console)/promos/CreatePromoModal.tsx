'use client';

import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { useQueryClient } from '@tanstack/react-query';
import { dict } from '@/lib/i18n';
import { newIdempotencyKey } from '@/lib/idempotency';
import { promoRepository } from '@/mocks/repositories';
import { Modal } from '@/components/Modal';
import { errorText, isSessionError } from '../_shared';

const inputClass =
  'w-full rounded-md border border-outline bg-surface px-md py-sm text-body-large text-ink-primary outline-none transition-colors duration-normal ease-standard focus:border-brand-primary dark:border-outline-dark dark:bg-surface-dark dark:text-ink-dark-primary';
const labelClass = 'text-label-large text-ink-primary dark:text-ink-dark-primary';

/** Country → ISO 4217 for the money inputs (max discount / budget). */
const COUNTRY_CURRENCY: Record<string, string> = {
  NG: 'NGN',
  KE: 'KES',
  GH: 'GHS',
  ZA: 'ZAR',
  UG: 'UGX',
};
const COUNTRIES = Object.keys(COUNTRY_CURRENCY);

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="flex flex-col gap-xs">
      <span className={labelClass}>{label}</span>
      {children}
    </div>
  );
}

/** Money is entered as integer minor units; the currency is display-only. */
function MinorUnitsInput({
  value,
  onChange,
  currency,
  label,
}: {
  value: string;
  onChange: (value: string) => void;
  currency: string;
  label: string;
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
        aria-label={label}
        className={inputClass}
      />
      <span className="text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
        {currency}
      </span>
    </div>
  );
}

export function CreatePromoModal({ open, onClose }: { open: boolean; onClose: () => void }) {
  const router = useRouter();
  const queryClient = useQueryClient();

  const [code, setCode] = useState('');
  const [country, setCountry] = useState(COUNTRIES[0]);
  const [percentOff, setPercentOff] = useState('');
  const [maxDiscount, setMaxDiscount] = useState('');
  const [budget, setBudget] = useState('');
  const [maxRedemptions, setMaxRedemptions] = useState('');
  const [startsAt, setStartsAt] = useState('');
  const [endsAt, setEndsAt] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // One key per create intent: reset when the form opens and after success;
  // reused while the same filled-in form is retried.
  const [createKey, setCreateKey] = useState(() => newIdempotencyKey());

  const reset = () => {
    setCode('');
    setCountry(COUNTRIES[0]);
    setPercentOff('');
    setMaxDiscount('');
    setBudget('');
    setMaxRedemptions('');
    setStartsAt('');
    setEndsAt('');
    setError(null);
    setCreateKey(newIdempotencyKey());
  };

  useEffect(() => {
    if (open) reset();
  }, [open]);

  const currency = COUNTRY_CURRENCY[country];
  const percent = Number.parseInt(percentOff, 10);
  const maxDiscountMinor = maxDiscount === '' ? undefined : Number.parseInt(maxDiscount, 10);
  const budgetMinor = Number.parseInt(budget, 10);
  const maxRed = Number.parseInt(maxRedemptions, 10);
  const valid =
    code.trim() !== '' &&
    Number.isInteger(percent) &&
    percent > 0 &&
    percent <= 100 &&
    (maxDiscountMinor === undefined || (Number.isInteger(maxDiscountMinor) && maxDiscountMinor >= 0)) &&
    Number.isInteger(budgetMinor) &&
    budgetMinor >= 0 &&
    Number.isInteger(maxRed) &&
    maxRed > 0 &&
    startsAt !== '' &&
    endsAt !== '';

  const submit = async () => {
    if (!valid || busy) return;
    setBusy(true);
    setError(null);
    try {
      await promoRepository.createPromo(
        {
          code: code.trim(),
          country,
          discountPercent: percent,
          maxDiscount:
            maxDiscountMinor !== undefined
              ? { amountMinor: maxDiscountMinor, currency }
              : undefined,
          budget: { amountMinor: budgetMinor, currency },
          maxRedemptions: maxRed,
          startsAt: new Date(startsAt),
          endsAt: new Date(endsAt),
        },
        createKey,
      );
      setCreateKey(newIdempotencyKey());
      void queryClient.invalidateQueries({ queryKey: ['promos'] });
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
      title={dict.promos.editor.createTitle}
      closeLabel={dict.common.close}
    >
      <form
        className="flex flex-col gap-lg"
        onSubmit={(e) => {
          e.preventDefault();
          void submit();
        }}
      >
        <Field label={dict.promos.editor.codeLabel}>
          <input
            type="text"
            value={code}
            onChange={(e) => setCode(e.target.value)}
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
                {(dict.dashboard.countries as Record<string, string>)[c] ?? c}
              </option>
            ))}
          </select>
        </Field>
        <Field label={dict.promos.editor.percentOffLabel}>
          <input
            type="number"
            min={1}
            max={100}
            step={1}
            inputMode="numeric"
            value={percentOff}
            onChange={(e) => setPercentOff(e.target.value)}
            className={inputClass}
          />
        </Field>
        <Field label={dict.promos.editor.maxDiscountLabel}>
          <MinorUnitsInput
            value={maxDiscount}
            onChange={setMaxDiscount}
            currency={currency}
            label={dict.promos.editor.maxDiscountLabel}
          />
        </Field>
        <Field label={dict.promos.editor.budgetLabel}>
          <MinorUnitsInput
            value={budget}
            onChange={setBudget}
            currency={currency}
            label={dict.promos.editor.budgetLabel}
          />
        </Field>
        <Field label={dict.promos.editor.maxRedemptionsLabel}>
          <input
            type="number"
            min={1}
            step={1}
            inputMode="numeric"
            value={maxRedemptions}
            onChange={(e) => setMaxRedemptions(e.target.value)}
            className={inputClass}
          />
        </Field>
        <Field label={dict.common.fromDate}>
          <input
            type="date"
            value={startsAt}
            onChange={(e) => setStartsAt(e.target.value)}
            className={inputClass}
          />
        </Field>
        <Field label={dict.promos.editor.expiresAtLabel}>
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
            {dict.promos.editor.saveCta}
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
