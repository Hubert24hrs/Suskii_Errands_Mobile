'use client';

import { useEffect, useRef, useState } from 'react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { dict } from '@/lib/i18n';
import { newIdempotencyKey } from '@/lib/idempotency';
import { supportRepository } from '@/mocks/repositories';
import type { SupportTicketMessage } from '@/mocks/types';
import { Modal } from '@/components/Modal';
import { StateBlock } from '@/components/StateBlock';
import { can, errorText, formatDateTime, isSessionError, useAdminSession } from '../../_shared';
import { ticketStatusChip } from '../SupportClient';

/** AI-authored messages are labelled honestly in the thread. */
function authorLabel(author: SupportTicketMessage['author']): string | null {
  return author === 'ai' ? dict.support.aiLabel : null;
}

function Bubble({ message }: { message: SupportTicketMessage }) {
  const isAgent = message.author === 'agent';
  const label = authorLabel(message.author);
  return (
    <div className={`flex ${isAgent ? 'justify-end' : 'justify-start'}`}>
      <div
        className={`max-w-[80%] rounded-lg px-lg py-md ${
          isAgent
            ? 'bg-brand-primary text-brand-on-primary'
            : 'border border-outline bg-surface-raised text-ink-primary dark:border-outline-dark dark:bg-surface-dark-raised dark:text-ink-dark-primary'
        }`}
      >
        {label ? (
          <p
            className={`mb-xs text-label-small ${
              isAgent
                ? 'text-brand-on-primary/80'
                : 'text-ink-secondary dark:text-ink-dark-secondary'
            }`}
          >
            {label}
          </p>
        ) : null}
        <p className="text-body-medium">{message.body}</p>
        <p
          className={`mt-xs text-label-small ${
            isAgent
              ? 'text-brand-on-primary/80'
              : 'text-ink-secondary dark:text-ink-dark-secondary'
          }`}
        >
          {formatDateTime(message.at)}
        </p>
      </div>
    </div>
  );
}

export function SupportThreadClient({ ticketId }: { ticketId: string }) {
  const router = useRouter();
  const queryClient = useQueryClient();
  const sessionQuery = useAdminSession();
  const role = sessionQuery.data?.admin.role;
  const mayRead = role !== undefined && can(role, 'support.read');
  const mayManage = role !== undefined && can(role, 'support.manage');

  const ticketQuery = useQuery({
    queryKey: ['support', 'detail', ticketId],
    queryFn: () => supportRepository.getTicket(ticketId),
    enabled: mayRead,
  });

  useEffect(() => {
    if (ticketQuery.error && isSessionError(ticketQuery.error)) router.replace('/sign-in');
  }, [ticketQuery.error, router]);

  const [body, setBody] = useState('');
  const [busy, setBusy] = useState(false);
  const [actionError, setActionError] = useState<string | null>(null);
  // One key per composed reply; reset after success or when the text changes.
  const [replyIntent, setReplyIntent] = useState<{ key: string; fingerprint: string } | null>(
    null,
  );
  // One key per close intent; rotated when the close dialog reopens.
  const [closeKey, setCloseKey] = useState(() => newIdempotencyKey());
  const [closeOpen, setCloseOpen] = useState(false);

  const bottomRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [ticketQuery.data?.messages.length]);

  const ticket = ticketQuery.data;

  const send = async () => {
    if (!ticket) return;
    const text = body.trim();
    if (text === '') return;
    const current =
      replyIntent && replyIntent.fingerprint === text
        ? replyIntent
        : { key: newIdempotencyKey(), fingerprint: text };
    setReplyIntent(current);
    setBusy(true);
    setActionError(null);
    try {
      await supportRepository.replyTicket(ticket.id, text, current.key);
      setReplyIntent(null);
      setBody('');
      void queryClient.invalidateQueries({ queryKey: ['support'] });
    } catch (e) {
      if (isSessionError(e)) {
        router.replace('/sign-in');
      } else {
        setActionError(errorText(e));
      }
    } finally {
      setBusy(false);
    }
  };

  const close = async () => {
    if (!ticket) return;
    setBusy(true);
    setActionError(null);
    try {
      await supportRepository.closeTicket(ticket.id, closeKey);
      setCloseKey(newIdempotencyKey());
      setCloseOpen(false);
      void queryClient.invalidateQueries({ queryKey: ['support'] });
    } catch (e) {
      if (isSessionError(e)) {
        router.replace('/sign-in');
      } else {
        setActionError(errorText(e));
      }
    } finally {
      setBusy(false);
    }
  };

  if (sessionQuery.isPending) {
    return <StateBlock variant="loading" />;
  }
  if (!mayRead) {
    return <StateBlock variant="error" errorMessage={dict.errors.ERR_PERMISSION_DENIED} />;
  }

  return (
    <div className="flex flex-col gap-xl">
      <Link
        href="/support"
        className="text-body-small text-brand-primary underline-offset-2 transition-colors duration-normal ease-standard hover:underline dark:text-brand-secondary"
      >
        ← {dict.common.back}
      </Link>

      {ticketQuery.isPending ? (
        <StateBlock variant="loading" />
      ) : ticketQuery.isError ? (
        <StateBlock
          variant="error"
          errorMessage={errorText(ticketQuery.error)}
          retryLabel={dict.common.retry}
          onRetry={() => void ticketQuery.refetch()}
        />
      ) : ticket ? (
        <>
          <div className="flex flex-wrap items-center justify-between gap-md">
            <div className="flex flex-wrap items-center gap-md">
              <h1 className="text-headline-medium text-ink-primary dark:text-ink-dark-primary">
                {ticket.subject}
              </h1>
              {ticketStatusChip(ticket.status)}
            </div>
            {mayManage && ticket.status !== 'closed' ? (
              <button
                type="button"
                onClick={() => {
                  setCloseKey(newIdempotencyKey());
                  setCloseOpen(true);
                }}
                className="rounded-md border border-error px-lg py-sm text-label-large text-error transition-colors duration-normal ease-standard hover:bg-error/10 dark:border-error-dark dark:text-error-dark dark:hover:bg-error-dark/20"
              >
                {dict.support.closeTicketCta}
              </button>
            ) : null}
          </div>

          <p className="text-body-small text-ink-secondary dark:text-ink-dark-secondary">
            {ticket.userName} · {dict.support.columns.assigned}:{' '}
            {ticket.assignedToAdminId ?? dict.support.unassigned}
          </p>

          <div className="flex flex-col gap-md">
            {ticket.messages.map((message) => (
              <Bubble key={message.id} message={message} />
            ))}
            <div ref={bottomRef} />
          </div>

          {mayManage && ticket.status !== 'closed' ? (
            <div className="flex flex-col gap-md">
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
                className="rounded-md border border-outline bg-surface px-md py-sm text-body-large text-ink-primary outline-none transition-colors duration-normal ease-standard placeholder:text-ink-secondary focus:border-brand-primary dark:border-outline-dark dark:bg-surface-dark dark:text-ink-dark-primary"
              />
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
          ) : null}

          {actionError ? (
            <p role="alert" className="text-body-small text-error dark:text-error-dark">
              {actionError}
            </p>
          ) : null}
        </>
      ) : null}

      <Modal
        open={closeOpen}
        onClose={() => setCloseOpen(false)}
        title={dict.support.closeTicketCta}
        closeLabel={dict.common.close}
      >
        <div className="flex flex-wrap gap-md">
          <button
            type="button"
            disabled={busy}
            onClick={() => void close()}
            className="rounded-md bg-brand-primary px-xl py-sm text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong disabled:opacity-50"
          >
            {dict.common.confirm}
          </button>
          <button
            type="button"
            onClick={() => setCloseOpen(false)}
            className="rounded-md border border-outline px-lg py-sm text-label-large text-ink-primary transition-colors duration-normal ease-standard hover:bg-surface-muted dark:border-outline-dark dark:text-ink-dark-primary dark:hover:bg-surface-dark-muted"
          >
            {dict.common.cancel}
          </button>
        </div>
      </Modal>
    </div>
  );
}
