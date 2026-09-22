'use client';

import { useEffect, useRef, useState } from 'react';
import Link from 'next/link';
import { useQuery } from '@tanstack/react-query';
import type { Dictionary } from '@/lib/i18n/en';
import type { Locale } from '@/lib/i18n';
import { newIdempotencyKey } from '@/lib/idempotency';
import { chatRepository, isAppError, requestRepository, userRepository } from '@/mocks/repositories';
import type { ChatMessage, JobRequest, JobStatus } from '@/mocks/types';
import { StateBlock } from '@/components/StateBlock';
import { StatusChip } from '@/components/StatusChip';
import { errorText, formatDateTime, statusLabel, statusTone } from '../../_shared';

/**
 * Chat definitely opens at PAID_HELD and stays open while the parties are in
 * contact (mirrors CHAT_OPEN_STATUSES in the mock repository).
 */
const CHAT_OPEN: ReadonlySet<JobStatus> = new Set([
  'paid_held',
  'assigned',
  'en_route',
  'arrived',
  'in_progress',
  'completed_by_provider',
]);

/**
 * After confirmation the thread stays writable for 24h (or while a dispute is
 * open) — the client cannot evaluate that window, so the composer stays
 * visible and a send that lands outside it fails with ERR_CHAT_CLOSED.
 */
const CHAT_AFTER_CONFIRM: ReadonlySet<JobStatus> = new Set([
  'confirmed',
  'settlement_pending',
  'settled',
  'closed',
  'disputed',
]);

/** Baseline fetch (resolves unknown ids) + live updates via watchJob. */
function useJob(jobId: string) {
  const query = useQuery({
    queryKey: ['requests', 'mine'],
    queryFn: async () => {
      const [active, history] = await Promise.all([
        requestRepository.getMyActiveJobs(),
        requestRepository.getMyRequestHistory({ limit: 50 }),
      ]);
      return [...active, ...history];
    },
  });
  const [live, setLive] = useState<JobRequest | undefined>(undefined);
  useEffect(() => requestRepository.watchJob(jobId, setLive), [jobId]);
  return { query, job: live ?? query.data?.find((r) => r.id === jobId) };
}

/** Labeled placeholder for non-text message bodies (no media upload in M7). */
function MessageBody({ message, dict }: { message: ChatMessage; dict: Dictionary }) {
  const labels = dict.chat.messageTypes as Record<string, string>;
  switch (message.type) {
    case 'text':
      return <span>{message.text}</span>;
    case 'image':
      return <span className="italic">{labels.photo}</span>;
    case 'voice_note':
      return <span className="italic">{labels.voiceNote ?? message.type}</span>;
    case 'location':
      return <span className="italic">{labels.location}</span>;
    case 'offer_card':
      return <span className="italic">{labels.offerCard}</span>;
    default:
      return <span>{message.text ?? labels.system}</span>;
  }
}

export function ChatClient({
  locale,
  jobId,
  dict,
}: {
  locale: Locale;
  jobId: string;
  dict: Dictionary;
}) {
  const { query, job } = useJob(jobId);

  const meQuery = useQuery({
    queryKey: ['user', 'me'],
    queryFn: () => userRepository.getProfile(),
  });
  const meId = meQuery.data?.id;

  const [messages, setMessages] = useState<ChatMessage[]>([]);
  useEffect(() => chatRepository.watchMessages(jobId, setMessages), [jobId]);

  // Read receipts: mark the counterparty's messages read as they are viewed.
  // A fresh key per invocation — each "mark what is currently visible" is a
  // new intent (a replayed key would not mark later messages).
  useEffect(() => {
    if (!meId) return;
    const hasUnread = messages.some(
      (m) => m.senderId !== meId && m.senderId !== 'system' && !m.readAt,
    );
    if (hasUnread) {
      void chatRepository.markMessagesRead(jobId, newIdempotencyKey()).catch(() => {});
    }
  }, [messages, meId, jobId]);

  const endRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    endRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [messages.length]);

  // One idempotency key per composed message: reused on send retry,
  // regenerated after a successful send or when the text changes.
  const [text, setText] = useState('');
  const [sendKey, setSendKey] = useState(() => newIdempotencyKey());
  const [busy, setBusy] = useState(false);
  const [sendError, setSendError] = useState<string | null>(null);
  const [chatClosed, setChatClosed] = useState(false);

  const send = async () => {
    const value = text.trim();
    if (!value || busy) return;
    setBusy(true);
    setSendError(null);
    try {
      await chatRepository.sendMessage({
        jobId,
        type: 'text',
        idempotencyKey: sendKey,
        text: value,
      });
      setText('');
      setSendKey(newIdempotencyKey());
    } catch (e) {
      if (isAppError(e, 'ERR_CHAT_CLOSED')) {
        setChatClosed(true);
      } else {
        setSendError(errorText(dict, e));
      }
    } finally {
      setBusy(false);
    }
  };

  if (query.isPending && job === undefined) {
    return (
      <div className="mx-auto w-full max-w-3xl px-lg py-xxxl">
        <StateBlock variant="loading" />
      </div>
    );
  }
  if (query.isError) {
    return (
      <div className="mx-auto w-full max-w-3xl px-lg py-xxxl">
        <StateBlock
          variant="error"
          errorMessage={errorText(dict, query.error)}
          retryLabel={dict.common.retry}
          onRetry={() => void query.refetch()}
        />
      </div>
    );
  }
  if (!job) {
    return (
      <div className="mx-auto w-full max-w-3xl px-lg py-xxxl">
        <StateBlock
          variant="empty"
          emptyTitle={dict.notFound.title}
          emptyBody={dict.notFound.body}
        />
        <div className="flex justify-center">
          <Link
            href={`/${locale}/requests`}
            className="rounded-md bg-brand-primary px-xl py-sm text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong"
          >
            {dict.common.back}
          </Link>
        </div>
      </div>
    );
  }

  const composerVisible =
    !chatClosed && (CHAT_OPEN.has(job.status) || CHAT_AFTER_CONFIRM.has(job.status));
  const lastOwnId = meId
    ? [...messages].reverse().find((m) => m.senderId === meId)?.id
    : undefined;

  return (
    <div className="mx-auto w-full max-w-3xl px-lg py-xxxl">
      <div className="flex flex-wrap items-center justify-between gap-md">
        <h1 className="text-headline-medium text-ink-primary dark:text-ink-dark-primary">
          {dict.chat.title}
        </h1>
        <StatusChip label={statusLabel(dict, job.status)} tone={statusTone(job.status)} />
      </div>

      <section className="mt-xxl rounded-lg border border-outline bg-surface-raised dark:border-outline-dark dark:bg-surface-dark-raised">
        {messages.length === 0 ? (
          <div className="p-xl">
            <StateBlock variant="empty" emptyTitle={dict.chat.empty} />
          </div>
        ) : (
          <ul className="flex max-h-[60vh] flex-col gap-md overflow-y-auto p-xl">
            {messages.map((message) => {
              if (message.type === 'system') {
                return (
                  <li key={message.id} className="text-center">
                    <span className="inline-block rounded-pill bg-surface-muted px-md py-xs text-body-small text-ink-secondary dark:bg-surface-dark-muted dark:text-ink-dark-secondary">
                      {message.text ?? dict.chat.messageTypes.system}
                    </span>
                  </li>
                );
              }
              const own = meId !== undefined && message.senderId === meId;
              return (
                <li
                  key={message.id}
                  className={`flex flex-col ${own ? 'items-end' : 'items-start'}`}
                >
                  <div
                    className={`max-w-[80%] rounded-lg px-lg py-md text-body-medium ${
                      own
                        ? 'bg-brand-primary text-brand-on-primary'
                        : 'border border-outline bg-surface text-ink-primary dark:border-outline-dark dark:bg-surface-dark dark:text-ink-dark-primary'
                    }`}
                  >
                    <MessageBody message={message} dict={dict} />
                  </div>
                  <span className="mt-xs flex items-center gap-sm text-body-small text-ink-secondary dark:text-ink-dark-secondary">
                    {formatDateTime(message.createdAt)}
                    {own && message.id === lastOwnId ? (
                      <span>{message.readAt ? dict.chat.read : dict.chat.delivered}</span>
                    ) : null}
                  </span>
                </li>
              );
            })}
            <div ref={endRef} />
          </ul>
        )}

        {composerVisible ? (
          <form
            className="border-t border-outline p-lg dark:border-outline-dark"
            onSubmit={(e) => {
              e.preventDefault();
              void send();
            }}
          >
            <div className="flex gap-md">
              <input
                type="text"
                value={text}
                onChange={(e) => {
                  setText(e.target.value);
                  setSendKey(newIdempotencyKey());
                }}
                placeholder={dict.chat.inputPlaceholder}
                aria-label={dict.chat.inputPlaceholder}
                className="min-w-0 flex-1 rounded-md border border-outline bg-surface px-lg py-md text-body-large text-ink-primary placeholder:text-ink-secondary focus:border-brand-primary focus:outline-none dark:border-outline-dark dark:bg-surface-dark dark:text-ink-dark-primary"
              />
              <button
                type="submit"
                disabled={busy || text.trim() === ''}
                className="rounded-md bg-brand-primary px-xl py-md text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong disabled:opacity-50"
              >
                {dict.chat.send}
              </button>
            </div>
            {sendError ? (
              <p role="alert" className="mt-sm text-body-small text-error dark:text-error-dark">
                {sendError}
              </p>
            ) : null}
          </form>
        ) : (
          <p className="border-t border-outline p-lg text-center text-body-medium text-ink-secondary dark:border-outline-dark dark:text-ink-dark-secondary">
            {dict.chat.closedNotice}
          </p>
        )}
      </section>

      <div className="mt-lg">
        <Link
          href={`/${locale}/requests/${job.id}`}
          className="text-label-large text-brand-primary hover:underline dark:text-brand-secondary"
        >
          {dict.common.back}
        </Link>
      </div>
    </div>
  );
}
