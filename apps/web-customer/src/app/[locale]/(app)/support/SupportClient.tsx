'use client';

import { useEffect, useState } from 'react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import type { Dictionary } from '@/lib/i18n/en';
import type { Locale } from '@/lib/i18n';
import { newIdempotencyKey } from '@/lib/idempotency';
import { isAppError, supportRepository } from '@/lib/repositories';
import type { SupportTicket, SupportTicketStatus } from '@/mocks/types';
import { Modal } from '@/components/Modal';
import { StateBlock } from '@/components/StateBlock';
import { StatusChip } from '@/components/StatusChip';

type ChipTone = 'neutral' | 'info' | 'success' | 'warning' | 'error';

/** Maps any error to localized copy; unknown codes fall back to ERR_INTERNAL. */
function errorText(dict: Dictionary, error: unknown): string {
  if (isAppError(error)) {
    const table = dict.errors as Record<string, string>;
    return table[error.code] ?? dict.errors.ERR_INTERNAL;
  }
  return dict.errors.ERR_INTERNAL;
}

export function statusLabel(dict: Dictionary, status: SupportTicketStatus): string {
  const table = dict.support.statuses as Record<string, string>;
  return table[status] ?? status;
}

export function statusTone(status: SupportTicketStatus): ChipTone {
  switch (status) {
    case 'open':
      return 'info';
    case 'awaiting_user':
      return 'warning';
    case 'resolved':
      return 'success';
    case 'closed':
      return 'neutral';
  }
}

/** en-NG formatting for both locales (pcm has no Intl locale data). */
export function formatDateTime(date: Date): string {
  return new Intl.DateTimeFormat('en-NG', {
    dateStyle: 'medium',
    timeStyle: 'short',
  }).format(date);
}

/** Last activity on a ticket (latest message, else creation). */
function updatedAt(ticket: SupportTicket): Date {
  return ticket.messages[ticket.messages.length - 1]?.createdAt ?? ticket.createdAt;
}

function TicketRow({
  ticket,
  locale,
  dict,
}: {
  ticket: SupportTicket;
  locale: Locale;
  dict: Dictionary;
}) {
  return (
    <Link
      href={`/${locale}/support/${ticket.id}`}
      className="block rounded-lg border border-outline bg-surface-raised p-xl transition-colors duration-normal ease-standard hover:border-brand-primary dark:border-outline-dark dark:bg-surface-dark-raised dark:hover:border-brand-secondary"
    >
      <div className="flex flex-wrap items-center justify-between gap-md">
        <p className="text-title-large text-ink-primary dark:text-ink-dark-primary">
          {ticket.subject}
        </p>
        <StatusChip label={statusLabel(dict, ticket.status)} tone={statusTone(ticket.status)} />
      </div>
      <p className="mt-sm text-body-small text-ink-secondary dark:text-ink-dark-secondary">
        {formatDateTime(updatedAt(ticket))}
      </p>
    </Link>
  );
}

function NewTicketModal({
  locale,
  dict,
  onClose,
}: {
  locale: Locale;
  dict: Dictionary;
  onClose: () => void;
}) {
  const router = useRouter();
  const [subject, setSubject] = useState('');
  const [body, setBody] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // One key per ticket intent; reset after success or when inputs change.
  const [intent, setIntent] = useState<{ key: string; fingerprint: string } | null>(null);

  const submit = async () => {
    const fingerprint = `${subject}|${body}`;
    const current =
      intent && intent.fingerprint === fingerprint
        ? intent
        : { key: newIdempotencyKey(), fingerprint };
    setIntent(current);
    setBusy(true);
    setError(null);
    try {
      const ticket = await supportRepository.createTicket({
        subject: subject.trim(),
        body: body.trim(),
        idempotencyKey: current.key,
      });
      setIntent(null);
      router.push(`/${locale}/support/${ticket.id}`);
    } catch (e) {
      setError(errorText(dict, e));
      setBusy(false);
    }
  };

  return (
    <Modal open onClose={onClose} title={dict.support.sheet.title} closeLabel={dict.common.close}>
      <div className="flex flex-col gap-lg">
        <div className="flex flex-col gap-xs">
          <label
            htmlFor="ticket-subject"
            className="text-label-large text-ink-primary dark:text-ink-dark-primary"
          >
            {dict.support.sheet.subjectLabel}
          </label>
          <input
            id="ticket-subject"
            type="text"
            value={subject}
            onChange={(e) => setSubject(e.target.value)}
            className="rounded-md border border-outline bg-surface-raised px-md py-sm text-body-large text-ink-primary outline-none transition-colors duration-normal ease-standard focus:border-brand-primary dark:border-outline-dark dark:bg-surface-dark-raised dark:text-ink-dark-primary"
          />
        </div>
        <div className="flex flex-col gap-xs">
          <label
            htmlFor="ticket-body"
            className="text-label-large text-ink-primary dark:text-ink-dark-primary"
          >
            {dict.support.sheet.bodyLabel}
          </label>
          <textarea
            id="ticket-body"
            rows={4}
            value={body}
            onChange={(e) => setBody(e.target.value)}
            className="rounded-md border border-outline bg-surface-raised px-md py-sm text-body-large text-ink-primary outline-none transition-colors duration-normal ease-standard focus:border-brand-primary dark:border-outline-dark dark:bg-surface-dark-raised dark:text-ink-dark-primary"
          />
        </div>
        {error ? (
          <p role="alert" className="text-body-small text-error dark:text-error-dark">
            {error}
          </p>
        ) : null}
        <button
          type="button"
          disabled={busy || subject.trim() === '' || body.trim() === ''}
          onClick={() => void submit()}
          className="rounded-md bg-brand-primary px-xl py-md text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong disabled:opacity-50"
        >
          {dict.support.sheet.createCta}
        </button>
      </div>
    </Modal>
  );
}

export function SupportClient({ locale, dict }: { locale: Locale; dict: Dictionary }) {
  const queryClient = useQueryClient();
  const query = useQuery({
    queryKey: ['support', 'tickets'],
    queryFn: () => supportRepository.getTickets(),
  });
  // Live updates: AI triage replies and status flips arrive via watchTickets.
  useEffect(
    () =>
      supportRepository.watchTickets((tickets) => {
        queryClient.setQueryData(['support', 'tickets'], tickets);
      }),
    [queryClient],
  );

  const [modalOpen, setModalOpen] = useState(false);

  return (
    <div className="mx-auto w-full max-w-5xl px-lg py-xxxl">
      <div className="flex flex-wrap items-center justify-between gap-md">
        <h1 className="text-headline-medium text-ink-primary dark:text-ink-dark-primary">
          {dict.support.title}
        </h1>
        <button
          type="button"
          onClick={() => setModalOpen(true)}
          className="rounded-md bg-brand-primary px-xl py-sm text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong"
        >
          {dict.support.newTicketCta}
        </button>
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
        ) : (query.data ?? []).length === 0 ? (
          <StateBlock variant="empty" emptyTitle={dict.support.empty} />
        ) : (
          <ul className="flex flex-col gap-lg">
            {(query.data ?? []).map((ticket) => (
              <li key={ticket.id}>
                <TicketRow ticket={ticket} locale={locale} dict={dict} />
              </li>
            ))}
          </ul>
        )}
      </div>

      {modalOpen ? (
        <NewTicketModal locale={locale} dict={dict} onClose={() => setModalOpen(false)} />
      ) : null}
    </div>
  );
}
