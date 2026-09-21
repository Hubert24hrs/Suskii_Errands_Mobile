'use client';

import { useRef, useState, type ChangeEvent } from 'react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { useMutation, useQuery } from '@tanstack/react-query';
import type { Dictionary } from '@/lib/i18n/en';
import type { Locale } from '@/lib/i18n';
import { newIdempotencyKey } from '@/lib/idempotency';
import {
  bootstrapRepository,
  catalogRepository,
  isAppError,
  requestRepository,
} from '@/mocks/repositories';
import type { CreateRequestInput, Urgency } from '@/mocks/types';
import { MoneyField } from '@/components/MoneyField';
import { MoneyText } from '@/components/MoneyText';
import { StateBlock } from '@/components/StateBlock';
import { categoryLabel, errorText, mediaName } from '../_shared';

const URGENCY_LEVELS: Urgency[] = ['flexible', 'standard', 'urgent', 'emergency'];

/**
 * One idempotency key per user intent (M3.14): the key survives retries of
 * the same intent and is regenerated when the inputs change or the intent
 * succeeds.
 */
function useIntentKey() {
  const ref = useRef<{ key: string; fingerprint: string } | null>(null);
  return {
    keyFor(fingerprint: string): string {
      if (!ref.current || ref.current.fingerprint !== fingerprint) {
        ref.current = { key: newIdempotencyKey(), fingerprint };
      }
      return ref.current.key;
    },
    reset() {
      ref.current = null;
    },
  };
}

const inputClasses =
  'rounded-md border border-outline bg-surface-raised px-md py-sm text-body-large text-ink-primary outline-none transition-colors duration-normal ease-standard focus:border-brand-primary placeholder:text-ink-secondary dark:border-outline-dark dark:bg-surface-dark-raised dark:text-ink-dark-primary dark:placeholder:text-ink-dark-secondary';

const labelClasses = 'text-label-large text-ink-primary dark:text-ink-dark-primary';

export function NewRequestClient({ locale, dict }: { locale: Locale; dict: Dictionary }) {
  const router = useRouter();

  const categoriesQuery = useQuery({
    queryKey: ['catalog', 'categories'],
    queryFn: () => catalogRepository.getCategories(),
  });
  // Bootstrap carries the country pack (currency) and syncs the server clock.
  const bootstrapQuery = useQuery({
    queryKey: ['bootstrap'],
    queryFn: () => bootstrapRepository.getBootstrap(),
  });
  const currency = bootstrapQuery.data?.countryPack.currencyCode ?? 'NGN';

  const [categoryId, setCategoryId] = useState('');
  const [description, setDescription] = useState('');
  const [pickupLabel, setPickupLabel] = useState('');
  const [landmark, setLandmark] = useState('');
  const [destinationLabel, setDestinationLabel] = useState('');
  const [urgency, setUrgency] = useState<Urgency>('standard');
  const [scheduleMode, setScheduleMode] = useState<'now' | 'later'>('now');
  const [scheduledAt, setScheduledAt] = useState('');
  const [preferredPriceMinor, setPreferredPriceMinor] = useState<number | null>(null);
  const [itemFloatMinor, setItemFloatMinor] = useState<number | null>(null);
  const [declaredValueMinor, setDeclaredValueMinor] = useState<number | null>(null);
  const [photoNames, setPhotoNames] = useState<string[]>([]);
  const [verificationRequired, setVerificationRequired] = useState(false);

  const priceBandQuery = useQuery({
    queryKey: ['catalog', 'priceBand', categoryId],
    queryFn: () => catalogRepository.getPriceBand({ categoryId }),
    enabled: categoryId !== '',
  });

  const draftIntent = useIntentKey();
  const publishIntent = useIntentKey();

  const buildInput = (): CreateRequestInput => ({
    categoryId,
    description: description.trim(),
    pickup: {
      label: pickupLabel.trim(),
      landmarkNote: landmark.trim() === '' ? undefined : landmark.trim(),
    },
    destination:
      destinationLabel.trim() === '' ? undefined : { label: destinationLabel.trim() },
    urgency,
    scheduledAt:
      scheduleMode === 'later' && scheduledAt !== '' ? new Date(scheduledAt) : undefined,
    preferredPrice:
      preferredPriceMinor === null
        ? undefined
        : { amountMinor: preferredPriceMinor, currency },
    itemFloat:
      itemFloatMinor === null ? undefined : { amountMinor: itemFloatMinor, currency },
    declaredValue:
      declaredValueMinor === null
        ? undefined
        : { amountMinor: declaredValueMinor, currency },
    mediaPaths: photoNames,
  });

  const fingerprint = () => JSON.stringify(buildInput());

  const saveDraft = useMutation({
    mutationFn: async () => {
      const draft = await requestRepository.createRequest(
        buildInput(),
        draftIntent.keyFor(fingerprint()),
      );
      return draft;
    },
    onSuccess: (draft) => {
      draftIntent.reset();
      router.push(`/${locale}/requests/${draft.id}`);
    },
  });

  const publish = useMutation({
    mutationFn: async () => {
      setVerificationRequired(false);
      // One intent = create the draft, then publish it. The same key covers
      // both calls so a retry after a mid-flow failure replays the create.
      const key = publishIntent.keyFor(fingerprint());
      const draft = await requestRepository.createRequest(buildInput(), key);
      return requestRepository.publishRequest(draft.id, key);
    },
    onSuccess: (published) => {
      publishIntent.reset();
      router.push(`/${locale}/requests/${published.id}`);
    },
    onError: (error) => {
      if (isAppError(error, 'ERR_VERIFICATION_REQUIRED')) {
        setVerificationRequired(true);
      }
    },
  });

  const canSubmit =
    categoryId !== '' && description.trim() !== '' && pickupLabel.trim() !== '';
  const busy = saveDraft.isPending || publish.isPending;
  const actionError = saveDraft.error ?? publish.error;
  const band = priceBandQuery.data;

  const onPhotos = (e: ChangeEvent<HTMLInputElement>) => {
    const files = Array.from(e.target.files ?? []).map((f) => f.name);
    if (files.length > 0) setPhotoNames((prev) => [...prev, ...files]);
    e.target.value = '';
  };

  if (categoriesQuery.isPending || bootstrapQuery.isPending) {
    return (
      <div className="mx-auto w-full max-w-3xl px-lg py-xxxl">
        <StateBlock variant="loading" />
      </div>
    );
  }
  if (categoriesQuery.isError || bootstrapQuery.isError) {
    return (
      <div className="mx-auto w-full max-w-3xl px-lg py-xxxl">
        <StateBlock
          variant="error"
          errorMessage={errorText(dict, categoriesQuery.error ?? bootstrapQuery.error)}
          retryLabel={dict.common.retry}
          onRetry={() => {
            void categoriesQuery.refetch();
            void bootstrapQuery.refetch();
          }}
        />
      </div>
    );
  }

  const categories = categoriesQuery.data;

  return (
    <div className="mx-auto w-full max-w-3xl px-lg py-xxxl">
      <h1 className="text-headline-medium text-ink-primary dark:text-ink-dark-primary">
        {dict.newRequest.title}
      </h1>

      <form
        className="mt-xxl flex flex-col gap-xl"
        onSubmit={(e) => {
          e.preventDefault();
          if (canSubmit && !busy) publish.mutate();
        }}
      >
        <div className="flex flex-col gap-xs">
          <label htmlFor="category" className={labelClasses}>
            {dict.newRequest.categoryLabel}
          </label>
          <select
            id="category"
            value={categoryId}
            onChange={(e) => setCategoryId(e.target.value)}
            className={inputClasses}
          >
            <option value="" disabled>
              {dict.newRequest.categoryLabel}
            </option>
            {categories.map((c) => (
              <option key={c.id} value={c.id}>
                {categoryLabel(dict, categories, c.id)}
              </option>
            ))}
          </select>
        </div>

        <div className="flex flex-col gap-xs">
          <label htmlFor="description" className={labelClasses}>
            {dict.newRequest.descriptionLabel}
          </label>
          <textarea
            id="description"
            rows={4}
            value={description}
            onChange={(e) => setDescription(e.target.value)}
            placeholder={dict.newRequest.descriptionHint}
            className={inputClasses}
          />
        </div>

        <div className="flex flex-col gap-xs">
          <label htmlFor="pickup" className={labelClasses}>
            {dict.newRequest.pickupLabel}
          </label>
          <input
            id="pickup"
            type="text"
            value={pickupLabel}
            onChange={(e) => setPickupLabel(e.target.value)}
            placeholder={dict.newRequest.pickupHint}
            className={inputClasses}
          />
        </div>

        <div className="flex flex-col gap-xs">
          <label htmlFor="landmark" className={labelClasses}>
            {dict.newRequest.landmarkLabel}
          </label>
          <input
            id="landmark"
            type="text"
            value={landmark}
            onChange={(e) => setLandmark(e.target.value)}
            className={inputClasses}
          />
        </div>

        <div className="flex flex-col gap-xs">
          <label htmlFor="destination" className={labelClasses}>
            {dict.newRequest.destinationLabel}
          </label>
          <input
            id="destination"
            type="text"
            value={destinationLabel}
            onChange={(e) => setDestinationLabel(e.target.value)}
            className={inputClasses}
          />
        </div>

        <fieldset className="flex flex-col gap-xs">
          <legend className={labelClasses}>{dict.newRequest.urgencyLabel}</legend>
          <div className="flex flex-wrap gap-sm">
            {URGENCY_LEVELS.map((level) => (
              <button
                key={level}
                type="button"
                onClick={() => setUrgency(level)}
                aria-pressed={urgency === level}
                className={`rounded-pill px-lg py-sm text-label-large transition-colors duration-normal ease-standard ${
                  urgency === level
                    ? 'bg-brand-primary text-brand-on-primary'
                    : 'border border-outline text-ink-primary hover:bg-surface-muted dark:border-outline-dark dark:text-ink-dark-primary dark:hover:bg-surface-dark-muted'
                }`}
              >
                {dict.newRequest.urgencyLevels[level]}
              </button>
            ))}
          </div>
        </fieldset>

        <fieldset className="flex flex-col gap-xs">
          <legend className={labelClasses}>{dict.newRequest.scheduleLabel}</legend>
          <div className="flex flex-wrap gap-sm">
            {(['now', 'later'] as const).map((mode) => (
              <button
                key={mode}
                type="button"
                onClick={() => setScheduleMode(mode)}
                aria-pressed={scheduleMode === mode}
                className={`rounded-pill px-lg py-sm text-label-large transition-colors duration-normal ease-standard ${
                  scheduleMode === mode
                    ? 'bg-brand-primary text-brand-on-primary'
                    : 'border border-outline text-ink-primary hover:bg-surface-muted dark:border-outline-dark dark:text-ink-dark-primary dark:hover:bg-surface-dark-muted'
                }`}
              >
                {mode === 'now' ? dict.newRequest.scheduleNow : dict.newRequest.scheduleLater}
              </button>
            ))}
          </div>
          {scheduleMode === 'later' ? (
            <input
              type="datetime-local"
              value={scheduledAt}
              onChange={(e) => setScheduledAt(e.target.value)}
              className={`${inputClasses} mt-sm`}
            />
          ) : null}
        </fieldset>

        <div className="flex flex-col gap-xs">
          <MoneyField
            label={dict.newRequest.preferredPriceLabel}
            currency={currency}
            valueMinor={preferredPriceMinor}
            onChange={setPreferredPriceMinor}
          />
          {band ? (
            <p className="text-body-small text-ink-secondary dark:text-ink-dark-secondary">
              {band.basis === 'history'
                ? dict.newRequest.priceBand.sampledHint
                : dict.newRequest.priceBand.typicalHint}
              {': '}
              <MoneyText
                amountMinor={band.p25.amountMinor}
                currency={band.p25.currency}
              />
              {' – '}
              <MoneyText
                amountMinor={band.p75.amountMinor}
                currency={band.p75.currency}
              />
            </p>
          ) : null}
        </div>

        <MoneyField
          label={dict.newRequest.itemFloatLabel}
          currency={currency}
          valueMinor={itemFloatMinor}
          onChange={setItemFloatMinor}
          hint={dict.newRequest.itemFloatHint}
        />

        <MoneyField
          label={dict.newRequest.declaredValueLabel}
          currency={currency}
          valueMinor={declaredValueMinor}
          onChange={setDeclaredValueMinor}
        />

        <div className="flex flex-col gap-xs">
          <span className={labelClasses}>{dict.requests.detail.photos}</span>
          {photoNames.length > 0 ? (
            <ul className="flex flex-wrap gap-sm">
              {photoNames.map((name, index) => (
                <li
                  key={`${name}-${index}`}
                  className="flex items-center gap-xs rounded-pill border border-outline px-md py-xs text-body-small text-ink-primary dark:border-outline-dark dark:text-ink-dark-primary"
                >
                  {mediaName(name)}
                  <button
                    type="button"
                    aria-label={dict.common.close}
                    onClick={() =>
                      setPhotoNames((prev) => prev.filter((_, i) => i !== index))
                    }
                    className="text-ink-secondary transition-colors duration-normal ease-standard hover:text-ink-primary dark:text-ink-dark-secondary dark:hover:text-ink-dark-primary"
                  >
                    ✕
                  </button>
                </li>
              ))}
            </ul>
          ) : null}
          <label className="w-fit cursor-pointer rounded-md border border-outline px-md py-sm text-label-large text-ink-primary transition-colors duration-normal ease-standard hover:bg-surface-muted dark:border-outline-dark dark:text-ink-dark-primary dark:hover:bg-surface-dark-muted">
            {dict.newRequest.photosAdd}
            <input type="file" multiple accept="image/*" className="hidden" onChange={onPhotos} />
          </label>
        </div>

        {verificationRequired ? (
          <div className="rounded-md border border-warning bg-warning/10 p-lg dark:border-warning-dark dark:bg-warning-dark/20">
            <p className="text-body-medium text-ink-primary dark:text-ink-dark-primary">
              {dict.newRequest.verificationRequiredNotice}
            </p>
            <Link
              href={`/${locale}/verify`}
              className="mt-sm inline-block rounded-md bg-brand-primary px-lg py-sm text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong"
            >
              {dict.verify.title}
            </Link>
          </div>
        ) : null}

        {actionError && !verificationRequired ? (
          <p role="alert" className="text-body-medium text-error dark:text-error-dark">
            {errorText(dict, actionError)}
          </p>
        ) : null}

        <div className="flex flex-wrap gap-md">
          <button
            type="button"
            disabled={!canSubmit || busy}
            onClick={() => saveDraft.mutate()}
            className="rounded-md border border-outline px-xl py-md text-label-large text-ink-primary transition-colors duration-normal ease-standard hover:bg-surface-muted disabled:opacity-50 dark:border-outline-dark dark:text-ink-dark-primary dark:hover:bg-surface-dark-muted"
          >
            {dict.newRequest.saveDraft}
          </button>
          <button
            type="submit"
            disabled={!canSubmit || busy}
            className="rounded-md bg-brand-primary px-xl py-md text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong disabled:opacity-50"
          >
            {dict.newRequest.publish}
          </button>
        </div>
      </form>
    </div>
  );
}
