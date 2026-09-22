'use client';

// AI Admin Assistant panel (read-only). The assistant never mutates domain
// data — sendMessage only appends to the chat transcript and replies with
// insight text plus proposed_action cards deep-linking into console
// modules. One idempotency key per message: kept while the text is
// unchanged (retry replays), regenerated on success or text change.

import { useEffect, useRef, useState } from 'react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { dict } from '@/lib/i18n';
import { newIdempotencyKey } from '@/lib/idempotency';
import { aiAdminRepository } from '@/mocks/repositories';
import type { AiAdminMessage } from '@/mocks/types';
import { StateBlock } from '@/components/StateBlock';
import { errorText, isSessionError } from '../_shared';

const inputClasses =
  'w-full rounded-md border border-outline bg-surface-raised px-md py-sm text-body-large text-ink-primary outline-none transition-colors duration-normal ease-standard focus:border-brand-primary placeholder:text-ink-secondary disabled:opacity-50 dark:border-outline-dark dark:bg-surface-dark-raised dark:text-ink-dark-primary dark:placeholder:text-ink-dark-secondary';

function actionHref(action: { module: string; targetId?: string }): string {
  return action.targetId === undefined ? action.module : `${action.module}/${action.targetId}`;
}

export function AiAssistant() {
  const router = useRouter();
  const [messages, setMessages] = useState<AiAdminMessage[] | null>(null);
  const [loadError, setLoadError] = useState<unknown>(null);
  const [loadAttempt, setLoadAttempt] = useState(0);
  const [input, setInput] = useState('');
  const [stream, setStream] = useState<{ question: string; partial: string } | null>(null);
  const [sendError, setSendError] = useState<unknown>(null);
  const bottomRef = useRef<HTMLDivElement | null>(null);
  const messageKeyRef = useRef<{ key: string; text: string } | null>(null);

  useEffect(() => {
    let cancelled = false;
    aiAdminRepository
      .listMessages()
      .then((list) => {
        if (!cancelled) setMessages(list);
      })
      .catch((e: unknown) => {
        if (cancelled) return;
        if (isSessionError(e)) router.replace('/sign-in');
        else setLoadError(e);
      });
    return () => {
      cancelled = true;
    };
  }, [loadAttempt, router]);

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ block: 'end' });
  }, [messages, stream]);

  const send = async () => {
    const text = input.trim();
    if (text === '' || stream !== null) return;
    setSendError(null);
    setInput('');
    if (messageKeyRef.current === null || messageKeyRef.current.text !== text) {
      messageKeyRef.current = { key: newIdempotencyKey(), text };
    }
    const key = messageKeyRef.current.key;
    setStream({ question: text, partial: '' });
    try {
      const reply = await aiAdminRepository.sendMessage(text, key, (partialBody) => {
        setStream((s) => (s === null ? s : { ...s, partial: partialBody }));
      });
      messageKeyRef.current = null;
      setMessages((prev) => [
        ...(prev ?? []),
        { id: `${reply.id}-q`, role: 'admin', body: text, at: reply.at },
        reply,
      ]);
      setStream(null);
    } catch (e) {
      setStream(null);
      if (isSessionError(e)) {
        router.replace('/sign-in');
      } else {
        // Key is kept so retrying the same text replays instead of re-running.
        setSendError(e);
      }
    }
  };

  return (
    <section className="flex flex-col gap-md rounded-lg border border-outline bg-surface-raised p-lg dark:border-outline-dark dark:bg-surface-dark-raised">
      <div className="flex flex-col gap-xxs">
        <h2 className="text-title-large text-ink-primary dark:text-ink-dark-primary">
          {dict.analytics.assistant.title}
        </h2>
        <p className="text-body-small text-ink-secondary dark:text-ink-dark-secondary">
          {dict.analytics.assistant.readOnlyNote}
        </p>
      </div>

      {loadError !== null ? (
        <StateBlock
          variant="error"
          errorMessage={errorText(loadError)}
          retryLabel={dict.common.retry}
          onRetry={() => {
            setLoadError(null);
            setLoadAttempt((a) => a + 1);
          }}
        />
      ) : messages === null ? (
        <StateBlock variant="loading" />
      ) : (
        <div className="flex max-h-96 flex-col gap-md overflow-y-auto" aria-live="polite">
          {messages.length === 0 && stream === null ? (
            <StateBlock variant="empty" emptyTitle={dict.common.emptyGeneric} />
          ) : null}
          {messages.map((message) =>
            message.role === 'admin' ? (
              <div key={message.id} className="flex justify-end">
                <p className="max-w-[80%] whitespace-pre-wrap rounded-lg bg-brand-primary px-md py-sm text-body-medium text-brand-on-primary">
                  {message.body}
                </p>
              </div>
            ) : (
              <div key={message.id} className="flex flex-col items-start gap-sm">
                <p className="max-w-[80%] whitespace-pre-wrap rounded-lg border border-outline bg-surface px-md py-sm text-body-medium text-ink-primary dark:border-outline-dark dark:bg-surface-dark dark:text-ink-dark-primary">
                  {message.body}
                </p>
                {message.proposedActions?.map((action) => (
                  <div
                    key={`${action.module}-${action.targetId ?? ''}`}
                    className="flex w-full max-w-md flex-col gap-xs rounded-lg border border-outline bg-surface-muted p-md dark:border-outline-dark dark:bg-surface-dark-muted"
                  >
                    <span className="text-label-small text-ink-secondary dark:text-ink-dark-secondary">
                      {dict.analytics.assistant.actionCardTitle}
                    </span>
                    <span className="text-body-medium text-ink-primary dark:text-ink-dark-primary">
                      {action.label}
                    </span>
                    <span className="text-body-small text-ink-secondary dark:text-ink-dark-secondary">
                      {action.rationale}
                    </span>
                    <Link
                      href={actionHref(action)}
                      className="mt-xs w-fit rounded-md bg-brand-primary px-lg py-sm text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong"
                    >
                      {dict.analytics.assistant.actionCardCta}
                    </Link>
                  </div>
                ))}
              </div>
            ),
          )}
          {stream !== null ? (
            <>
              <div className="flex justify-end">
                <p className="max-w-[80%] whitespace-pre-wrap rounded-lg bg-brand-primary px-md py-sm text-body-medium text-brand-on-primary">
                  {stream.question}
                </p>
              </div>
              <div className="flex justify-start">
                <p className="max-w-[80%] whitespace-pre-wrap rounded-lg border border-outline bg-surface px-md py-sm text-body-medium text-ink-primary dark:border-outline-dark dark:bg-surface-dark dark:text-ink-dark-primary">
                  {stream.partial === '' ? dict.analytics.assistant.thinking : stream.partial}
                </p>
              </div>
            </>
          ) : null}
          <div ref={bottomRef} />
        </div>
      )}

      {sendError !== null ? (
        <p role="alert" className="text-body-medium text-error dark:text-error-dark">
          {errorText(sendError)}
        </p>
      ) : null}

      <form
        className="flex gap-sm"
        onSubmit={(e) => {
          e.preventDefault();
          void send();
        }}
      >
        <input
          type="text"
          value={input}
          onChange={(e) => setInput(e.target.value)}
          placeholder={dict.analytics.assistant.inputPlaceholder}
          disabled={stream !== null}
          className={inputClasses}
        />
        <button
          type="submit"
          disabled={stream !== null || input.trim() === ''}
          className="rounded-md bg-brand-primary px-xl py-sm text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong disabled:opacity-50"
        >
          {dict.analytics.assistant.send}
        </button>
      </form>
    </section>
  );
}
