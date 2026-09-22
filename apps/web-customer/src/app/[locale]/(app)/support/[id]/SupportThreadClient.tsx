'use client';

import { useEffect, useRef, useState } from 'react';
import Link from 'next/link';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import type { Dictionary } from '@/lib/i18n/en';
import type { Locale } from '@/lib/i18n';
import { newIdempotencyKey } from '@/lib/idempotency';
import { isAppError, supportRepository } from '@/mocks/repositories';
import type { SupportMessage } from '@/mocks/types';
import { StateBlock } from '@/components/StateBlock';
import { StatusChip } from '@/components/StatusChip';
import { formatDateTime, statusLabel, statusTone } from '../SupportClient';

/** Maps any error to localized copy; unknown codes fall back to ERR_INTERNAL. */
function errorText(dict: Dictionary, error: unknown): string {
  if (isAppError(error)) {
    const table = dict.errors as Record<string, string>;
    return table[error.code] ?? dict.errors.ERR_INTERNAL;
  }
  return dict.errors.ERR_INTERNAL;
}

function MessageBubble({ message, dict }: { message: SupportMessage; dict: Dictionary }) {
  return (
    <div className={`flex ${message.fromUser ? 'justify-end' : 'justify-start'}`}>
      <div
        className={`max-w-[80%] rounded-lg px-lg py-md ${
          message.fromUser
            ? 'bg-brand-primary text-brand-on-primary'
            : 'border border-outline bg-surface-raised text-ink-primary dark:border-outline-dark dark:bg-surface-dark-raised dark:text-ink-dark-primary'
        }`}
      >
        {message.aiTriage ? (
          <p
            className={`mb-xs text-label-small ${
              message.fromUser
                ? 'text-brand-on-primary/80'
                : 'text-ink-secondary dark:text-ink-dark-secondary'
            }`}
          >
            {dict.support.aiTriageLabel}
          </p>
        ) : null}
        <p className="text-body-medium">{message.body}</p>
        <p
          className={`mt-xs text-label-small ${
            message.fromUser
              ? 'text-brand-on-primary/80'
              : 'text-ink-secondary dark:text-ink-dark-secondary'
          }`}
        >
          {formatDateTime(message.createdAt)}
        </p>
      </div>
    </div>
  );
}

export function SupportThreadClient({
  locale,
  dict,
  ticketId,
}: {
  locale: Locale;
  dict: Dictionary;
  ticketId: string;
}) {
  const queryClient = useQueryClient();
  const query = useQuery({
    queryKey: ['support', 'tickets'],
    queryFn: () => supportRepository.getTickets(),
  });
  // The thread is derived from the watched ticket list — AI triage replies
  // and status changes land here live.
  useEffect(
    () =>
      supportRepository.watchTickets((tickets) => {
        queryClient.setQueryData(['support', 'tickets'], tickets);
      }),
    [queryClient],
  );

  const ticket = query.data?.find((t) => t.id === ticketId);

  const [body, setBody] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // One key per composed reply; reset after success or when the text changes.
  const [intent, setIntent] = useState<{ key: string; fingerprint: string } | null>(null);

  const bottomRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [ticket?.messages.length]);

  const send = async () => {
    if (!ticket) return;
    const text = body.trim();
    if (text === '') return;
    const current =
      intent && intent.fingerprint === text ? intent : { key: newIdempotencyKey(), fingerprint: text };
    setIntent(current);
    setBusy(true);
    setError(null);
    try {
      await supportRepository.replyToTicket(ticket.id, text, current.key);
      setIntent(null);
      setBody('');
    } catch (e) {
      setError(errorText(dict, e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="mx-auto w-full max-w-5xl px-lg py-xxxl">
      <Link
        href={`/${locale}/support`}
        className="text-body-small text-brand-primary underline-offset-2 transition-colors duration-normal ease-standard hover:underline dark:text-brand-secondary"
      >
        ← {dict.common.back}
      </Link>

      {query.isPending ? (
        <div className="mt-xxl">
          <StateBlock variant="loading" />
        </div>
      ) : query.isError ? (
        <div className="mt-xxl">
          <StateBlock
            variant="error"
            errorMessage={errorText(dict, query.error)}
            retryLabel={dict.common.retry}
            onRetry={() => void query.refetch()}
          />
        </div>
      ) : !ticket ? (
        <div className="mt-xxl">
          <StateBlock
            variant="empty"
            emptyTitle={dict.notFound.title}
            emptyBody={dict.notFound.body}
          />
        </div>
      ) : (
        <>
          <div className="mt-lg flex flex-wrap items-center justify-between gap-md">
            <h1 className="text-headline-medium text-ink-primary dark:text-ink-dark-primary">
              {ticket.subject}
            </h1>
            <StatusChip label={statusLabel(dict, ticket.status)} tone={statusTone(ticket.status)} />
          </div>

          <h2 className="mt-xxl text-title-large text-ink-primary dark:text-ink-dark-primary">
            {dict.support.threadTitle}
          </h2>
          <div className="mt-lg flex flex-col gap-md">
            {ticket.messages.map((message) => (
              <MessageBubble key={message.id} message={message} dict={dict} />
            ))}
            <div ref={bottomRef} />
          </div>

          <div className="mt-xxl flex flex-col gap-md">
            <label
              htmlFor="ticket-reply"
              className="text-label-large text-ink-primary dark:text-ink-dark-primary"
            >
              {dict.support.replyPlaceholder}
            </label>
            <textarea
              id="ticket-reply"
              rows={3}
              value={body}
              onChange={(e) => setBody(e.target.value)}
              placeholder={dict.support.replyPlaceholder}
              className="rounded-md border border-outline bg-surface-raised px-md py-sm text-body-large text-ink-primary outline-none transition-colors duration-normal ease-standard focus:border-brand-primary dark:border-outline-dark dark:bg-surface-dark-raised dark:text-ink-dark-primary"
            />
            {error ? (
              <p role="alert" className="text-body-small text-error dark:text-error-dark">
                {error}
              </p>
            ) : null}
            <div>
              <button
                type="button"
                disabled={busy || body.trim() === ''}
                onClick={() => void send()}
                className="rounded-md bg-brand-primary px-xl py-sm text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong disabled:opacity-50"
              >
                {dict.support.replySend}
              </button>
            </div>
          </div>
        </>
      )}
    </div>
  );
}
