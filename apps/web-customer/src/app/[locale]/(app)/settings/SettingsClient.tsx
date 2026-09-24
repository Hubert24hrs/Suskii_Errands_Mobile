'use client';

import { useEffect, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import type { Dictionary } from '@/lib/i18n/en';
import { newIdempotencyKey } from '@/lib/idempotency';
import { ErrorCodes, isAppError, settingsRepository } from '@/lib/repositories';
import type { NotificationPreferences } from '@/mocks/types';
import { Modal } from '@/components/Modal';
import { StateBlock } from '@/components/StateBlock';

/** Maps any error to localized copy; unknown codes fall back to ERR_INTERNAL. */
function errorText(dict: Dictionary, error: unknown): string {
  if (isAppError(error)) {
    const table = dict.errors as Record<string, string>;
    return table[error.code] ?? dict.errors.ERR_INTERNAL;
  }
  return dict.errors.ERR_INTERNAL;
}

/** Fallback for dict keys not yet added — renders the key path (reported missing). */
function missingKey(dict: Dictionary, path: string): string {
  const value = path.split('.').reduce<unknown>(
    (acc, part) => (acc && typeof acc === 'object' ? (acc as Record<string, unknown>)[part] : undefined),
    dict,
  );
  return typeof value === 'string' ? value : path;
}

/** en-NG formatting for both locales (pcm has no Intl locale data). */
function formatDate(date: Date): string {
  return new Intl.DateTimeFormat('en-NG', { dateStyle: 'long' }).format(date);
}

/** 'HH:MM' → minutes since midnight (quiet hours wire format). */
function toMinutes(hhmm: string): number {
  const [h, m] = hhmm.split(':').map(Number);
  return (h || 0) * 60 + (m || 0);
}

function toHhmm(minutes: number | undefined): string {
  if (minutes === undefined) return '';
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  return `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}`;
}

const inputClass =
  'rounded-md border border-outline bg-surface-raised px-md py-sm text-body-large text-ink-primary outline-none transition-colors duration-normal ease-standard focus:border-brand-primary dark:border-outline-dark dark:bg-surface-dark-raised dark:text-ink-dark-primary';

const labelClass = 'text-label-large text-ink-primary dark:text-ink-dark-primary';

const sectionClass =
  'rounded-lg border border-outline bg-surface-raised p-xl dark:border-outline-dark dark:bg-surface-dark-raised';

function Toggle({
  id,
  label,
  checked,
  onChange,
}: {
  id: string;
  label: string;
  checked: boolean;
  onChange: (checked: boolean) => void;
}) {
  return (
    <label
      htmlFor={id}
      className="flex items-center justify-between gap-md text-body-large text-ink-primary dark:text-ink-dark-primary"
    >
      {label}
      <input
        id={id}
        type="checkbox"
        role="switch"
        checked={checked}
        onChange={(e) => onChange(e.target.checked)}
        className="h-5 w-5 accent-brand-primary"
      />
    </label>
  );
}

function NotificationsSection({ dict }: { dict: Dictionary }) {
  const queryClient = useQueryClient();
  const query = useQuery({
    queryKey: ['settings', 'notificationPrefs'],
    queryFn: () => settingsRepository.getNotificationPreferences(),
  });
  const [prefs, setPrefs] = useState<NotificationPreferences | null>(null);
  useEffect(() => {
    if (query.data) setPrefs(query.data);
  }, [query.data]);

  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // One key per save intent; reset after success or when the prefs change.
  const [intent, setIntent] = useState<{ key: string; fingerprint: string } | null>(null);

  const quietEnabled = prefs?.quietStartMinutes !== undefined;

  const update = (patch: Partial<NotificationPreferences>) => {
    setPrefs((current) => (current ? { ...current, ...patch } : current));
  };

  const save = async () => {
    if (!prefs) return;
    const fingerprint = JSON.stringify(prefs);
    const current =
      intent && intent.fingerprint === fingerprint
        ? intent
        : { key: newIdempotencyKey(), fingerprint };
    setIntent(current);
    setBusy(true);
    setError(null);
    try {
      await settingsRepository.updateNotificationPreferences(prefs, current.key);
      setIntent(null);
      queryClient.setQueryData(['settings', 'notificationPrefs'], prefs);
    } catch (e) {
      setError(errorText(dict, e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <section className={sectionClass}>
      <h2 className="text-title-large text-ink-primary dark:text-ink-dark-primary">
        {dict.settings.notificationsTitle}
      </h2>
      {query.isPending || !prefs ? (
        <div className="mt-lg">
          <StateBlock variant="loading" />
        </div>
      ) : query.isError ? (
        <StateBlock
          variant="error"
          errorMessage={errorText(dict, query.error)}
          retryLabel={dict.common.retry}
          onRetry={() => void query.refetch()}
        />
      ) : (
        <div className="mt-lg flex flex-col gap-lg">
          <Toggle
            id="prefs-push"
            label={dict.settings.channels.push}
            checked={prefs.push}
            onChange={(push) => update({ push })}
          />
          <Toggle
            id="prefs-email"
            label={dict.settings.channels.email}
            checked={prefs.email}
            onChange={(email) => update({ email })}
          />

          <div className="flex flex-col gap-sm border-t border-outline pt-lg dark:border-outline-dark">
            <Toggle
              id="prefs-quiet-enabled"
              label={dict.settings.quietHours}
              checked={quietEnabled}
              onChange={(enabled) =>
                update(
                  enabled
                    ? { quietStartMinutes: 22 * 60, quietEndMinutes: 7 * 60 }
                    : { quietStartMinutes: undefined, quietEndMinutes: undefined },
                )
              }
            />
            {!quietEnabled ? (
              <span className="text-body-small text-ink-secondary dark:text-ink-dark-secondary">
                {dict.settings.quietOff}
              </span>
            ) : null}
            {quietEnabled ? (
              <div className="flex flex-wrap items-center gap-lg">
                <label htmlFor="quiet-from" className="flex items-center gap-sm text-body-medium text-ink-primary dark:text-ink-dark-primary">
                  {dict.settings.quietFrom}
                  <input
                    id="quiet-from"
                    type="time"
                    value={toHhmm(prefs.quietStartMinutes)}
                    onChange={(e) => update({ quietStartMinutes: toMinutes(e.target.value) })}
                    className={inputClass}
                  />
                </label>
                <label htmlFor="quiet-to" className="flex items-center gap-sm text-body-medium text-ink-primary dark:text-ink-dark-primary">
                  {dict.settings.quietTo}
                  <input
                    id="quiet-to"
                    type="time"
                    value={toHhmm(prefs.quietEndMinutes)}
                    onChange={(e) => update({ quietEndMinutes: toMinutes(e.target.value) })}
                    className={inputClass}
                  />
                </label>
              </div>
            ) : null}
          </div>

          {error ? (
            <p role="alert" className="text-body-small text-error dark:text-error-dark">
              {error}
            </p>
          ) : null}
          <div>
            <button
              type="button"
              disabled={busy}
              onClick={() => void save()}
              className="rounded-md bg-brand-primary px-xl py-sm text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong disabled:opacity-50"
            >
              {dict.common.save}
            </button>
          </div>
        </div>
      )}
    </section>
  );
}

function TrustedContactsSection({ dict }: { dict: Dictionary }) {
  const queryClient = useQueryClient();
  const query = useQuery({
    queryKey: ['settings', 'trustedContacts'],
    queryFn: () => settingsRepository.getTrustedContacts(),
  });

  const [name, setName] = useState('');
  const [phone, setPhone] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // One key per add intent; reset after success or when the inputs change.
  const [addIntent, setAddIntent] = useState<{ key: string; fingerprint: string } | null>(null);
  // One key per remove intent, so a failed remove retries with the same key.
  const [removeIntent, setRemoveIntent] = useState<{
    contactId: string;
    key: string;
  } | null>(null);

  const contacts = query.data ?? [];

  const add = async () => {
    const fingerprint = `${name}|${phone}`;
    const current =
      addIntent && addIntent.fingerprint === fingerprint
        ? addIntent
        : { key: newIdempotencyKey(), fingerprint };
    setAddIntent(current);
    setBusy(true);
    setError(null);
    try {
      await settingsRepository.addTrustedContact({
        name: name.trim(),
        phoneE164: phone.trim(),
        idempotencyKey: current.key,
      });
      setAddIntent(null);
      setName('');
      setPhone('');
      await queryClient.invalidateQueries({ queryKey: ['settings', 'trustedContacts'] });
    } catch (e) {
      // The 6th contact throws ERR_INVALID_STATE — show the cap note.
      setError(
        isAppError(e, ErrorCodes.invalidState)
          ? dict.settings.contactLimitNote
          : errorText(dict, e),
      );
    } finally {
      setBusy(false);
    }
  };

  const remove = async (contactId: string) => {
    const current =
      removeIntent && removeIntent.contactId === contactId
        ? removeIntent
        : { contactId, key: newIdempotencyKey() };
    setRemoveIntent(current);
    setError(null);
    try {
      await settingsRepository.removeTrustedContact(contactId, current.key);
      setRemoveIntent(null);
      await queryClient.invalidateQueries({ queryKey: ['settings', 'trustedContacts'] });
    } catch (e) {
      setError(errorText(dict, e));
    }
  };

  return (
    <section className={sectionClass}>
      <h2 className="text-title-large text-ink-primary dark:text-ink-dark-primary">
        {dict.settings.trustedContactsTitle}
      </h2>
      {query.isPending ? (
        <div className="mt-lg">
          <StateBlock variant="loading" />
        </div>
      ) : query.isError ? (
        <StateBlock
          variant="error"
          errorMessage={errorText(dict, query.error)}
          retryLabel={dict.common.retry}
          onRetry={() => void query.refetch()}
        />
      ) : (
        <div className="mt-lg flex flex-col gap-lg">
          {contacts.length === 0 ? (
            <p className="text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
              {dict.settings.trustedContactsEmpty}
            </p>
          ) : (
            <ul className="flex flex-col gap-md">
              {contacts.map((contact) => (
                <li
                  key={contact.id}
                  className="flex flex-wrap items-center justify-between gap-md rounded-md border border-outline px-lg py-md dark:border-outline-dark"
                >
                  <div>
                    <p className="text-body-large text-ink-primary dark:text-ink-dark-primary">
                      {contact.name}
                    </p>
                    <p className="text-body-small text-ink-secondary dark:text-ink-dark-secondary">
                      {contact.phoneE164}
                    </p>
                  </div>
                  <button
                    type="button"
                    onClick={() => void remove(contact.id)}
                    aria-label={missingKey(dict, 'common.remove')}
                    className="rounded-md border border-outline px-lg py-sm text-label-large text-error transition-colors duration-normal ease-standard hover:bg-surface-muted dark:border-outline-dark dark:text-error-dark dark:hover:bg-surface-dark-muted"
                  >
                    {missingKey(dict, 'common.remove')}
                  </button>
                </li>
              ))}
            </ul>
          )}

          <div className="flex flex-col gap-md border-t border-outline pt-lg dark:border-outline-dark">
            <div className="flex flex-col gap-xs">
              <label htmlFor="contact-name" className={labelClass}>
                {dict.settings.contactName}
              </label>
              <input
                id="contact-name"
                type="text"
                value={name}
                onChange={(e) => setName(e.target.value)}
                className={inputClass}
              />
            </div>
            <div className="flex flex-col gap-xs">
              <label htmlFor="contact-phone" className={labelClass}>
                {dict.settings.contactPhone}
              </label>
              <input
                id="contact-phone"
                type="tel"
                value={phone}
                onChange={(e) => setPhone(e.target.value)}
                placeholder={dict.auth.phoneHint}
                className={inputClass}
              />
            </div>
            {error ? (
              <p role="alert" className="text-body-small text-error dark:text-error-dark">
                {error}
              </p>
            ) : null}
            <div>
              <button
                type="button"
                disabled={busy || name.trim() === '' || phone.trim() === ''}
                onClick={() => void add()}
                className="rounded-md bg-brand-primary px-xl py-sm text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong disabled:opacity-50"
              >
                {dict.settings.addContact}
              </button>
            </div>
          </div>
        </div>
      )}
    </section>
  );
}

function DataSection({ dict }: { dict: Dictionary }) {
  const [exportRef, setExportRef] = useState<string | null>(null);
  const [exportKey, setExportKey] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const requestExport = async () => {
    // A successful export starts a new intent for the next click; a failed
    // one retries with the same key.
    const key = exportRef === null && exportKey !== null ? exportKey : newIdempotencyKey();
    setExportKey(key);
    setBusy(true);
    setError(null);
    try {
      const reference = await settingsRepository.requestDataExport(key);
      setExportRef(reference);
    } catch (e) {
      setError(errorText(dict, e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <section className={sectionClass}>
      <div className="flex flex-col gap-md">
        <div>
          <button
            type="button"
            disabled={busy}
            onClick={() => void requestExport()}
            className="rounded-md border border-outline px-lg py-sm text-label-large text-ink-primary transition-colors duration-normal ease-standard hover:bg-surface-muted disabled:opacity-50 dark:border-outline-dark dark:text-ink-dark-primary dark:hover:bg-surface-dark-muted"
          >
            {dict.settings.dataExport}
          </button>
        </div>
        {exportRef ? (
          <p className="break-all rounded-md bg-surface-muted px-md py-sm font-mono text-body-small text-ink-secondary dark:bg-surface-dark-muted dark:text-ink-dark-secondary">
            {exportRef}
          </p>
        ) : null}
        {error ? (
          <p role="alert" className="text-body-small text-error dark:text-error-dark">
            {error}
          </p>
        ) : null}
      </div>
    </section>
  );
}

function DeleteAccountSection({ dict }: { dict: Dictionary }) {
  const [open, setOpen] = useState(false);
  const [scheduledAt, setScheduledAt] = useState<Date | null>(null);
  const [key, setKey] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const confirm = async () => {
    // One key per deletion intent; a retry after failure reuses it.
    const current = key ?? newIdempotencyKey();
    setKey(current);
    setBusy(true);
    setError(null);
    try {
      const date = await settingsRepository.requestAccountDeletion(current);
      setScheduledAt(date);
      setKey(null);
    } catch (e) {
      setError(errorText(dict, e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <section className={`${sectionClass} border-error/40 dark:border-error-dark/40`}>
      {scheduledAt ? (
        <div className="flex flex-col gap-sm">
          <p className="text-body-large text-ink-primary dark:text-ink-dark-primary">
            {dict.settings.deleteConfirmBody}
          </p>
          <p className="text-body-large text-error dark:text-error-dark">
            {formatDate(scheduledAt)}
          </p>
        </div>
      ) : (
        <button
          type="button"
          onClick={() => {
            setError(null);
            setOpen(true);
          }}
          className="rounded-md bg-error px-xl py-sm text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:opacity-90 dark:bg-error-dark"
        >
          {dict.settings.deleteAccount}
        </button>
      )}

      <Modal
        open={open}
        onClose={() => setOpen(false)}
        title={dict.settings.deleteConfirmTitle}
        closeLabel={dict.common.close}
      >
        <div className="flex flex-col gap-lg">
          <p className="text-body-large text-ink-primary dark:text-ink-dark-primary">
            {dict.settings.deleteConfirmBody}
          </p>
          {error ? (
            <p role="alert" className="text-body-small text-error dark:text-error-dark">
              {error}
            </p>
          ) : null}
          <div className="flex flex-wrap gap-md">
            <button
              type="button"
              disabled={busy}
              onClick={() => void confirm()}
              className="rounded-md bg-error px-xl py-sm text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:opacity-90 disabled:opacity-50 dark:bg-error-dark"
            >
              {dict.settings.deleteConfirmCta}
            </button>
            <button
              type="button"
              onClick={() => setOpen(false)}
              className="rounded-md border border-outline px-lg py-sm text-label-large text-ink-primary transition-colors duration-normal ease-standard hover:bg-surface-muted dark:border-outline-dark dark:text-ink-dark-primary dark:hover:bg-surface-dark-muted"
            >
              {dict.common.cancel}
            </button>
          </div>
        </div>
      </Modal>
    </section>
  );
}

export function SettingsClient({ dict }: { dict: Dictionary }) {
  return (
    <div className="mx-auto w-full max-w-5xl px-lg py-xxxl">
      <h1 className="text-headline-medium text-ink-primary dark:text-ink-dark-primary">
        {dict.settings.title}
      </h1>
      <div className="mt-xxl flex flex-col gap-xxl">
        <NotificationsSection dict={dict} />
        <TrustedContactsSection dict={dict} />
        <DataSection dict={dict} />
        <DeleteAccountSection dict={dict} />
        <p className="text-body-small text-ink-secondary dark:text-ink-dark-secondary">
          {dict.settings.languageNote}
        </p>
      </div>
    </div>
  );
}
