'use client';

// Text concierge chat (M7). All intelligence is server-side in
// MockConciergeRepository: this component only starts a conversation,
// streams assistant replies chunk by chunk, and renders the proposed
// action cards. The concierge never publishes/accepts/pays — the publish
// card is a user tap on RequestRepository.publishRequest (see PublishCard).

import { useEffect, useRef, useState } from 'react';
import Link from 'next/link';
import { useQuery } from '@tanstack/react-query';
import type { Dictionary } from '@/lib/i18n/en';
import type { Locale } from '@/lib/i18n';
import { newIdempotencyKey } from '@/lib/idempotency';
import {
  bootstrapRepository,
  catalogRepository,
  conciergeRepository,
} from '@/lib/repositories';
import type { ConciergeDraft, ConciergeMessage, ServiceCategory } from '@/mocks/types';
import { StateBlock } from '@/components/StateBlock';
import { StatusChip } from '@/components/StatusChip';
import { categoryLabel, errorText, urgencyLabel } from '../requests/_shared';
import { PublishCard } from './PublishCard';

const inputClasses =
  'w-full rounded-md border border-outline bg-surface-raised px-md py-sm text-body-large text-ink-primary outline-none transition-colors duration-normal ease-standard focus:border-brand-primary placeholder:text-ink-secondary disabled:opacity-50 dark:border-outline-dark dark:bg-surface-dark-raised dark:text-ink-dark-primary dark:placeholder:text-ink-dark-secondary';

const cardClasses =
  'mt-sm w-full max-w-md rounded-lg border border-outline bg-surface-raised p-lg dark:border-outline-dark dark:bg-surface-dark-raised';

function UserBubble({ text }: { text: string }) {
  return (
    <div className="flex justify-end">
      <p className="max-w-[80%] whitespace-pre-wrap rounded-lg bg-brand-primary px-md py-sm text-body-medium text-brand-on-primary">
        {text}
      </p>
    </div>
  );
}

function AssistantBubble({ text }: { text: string }) {
  return (
    <div className="flex justify-start">
      <p className="max-w-[80%] whitespace-pre-wrap rounded-lg border border-outline bg-surface-raised px-md py-sm text-body-medium text-ink-primary dark:border-outline-dark dark:bg-surface-dark-raised dark:text-ink-dark-primary">
        {text}
      </p>
    </div>
  );
}

/** Slots the concierge has extracted so far, rendered as read-only chips. */
function SlotChips({
  dict,
  draft,
  categories,
}: {
  dict: Dictionary;
  draft: ConciergeDraft;
  categories: ServiceCategory[];
}) {
  const chips: string[] = [];
  if (draft.categoryId !== undefined) {
    chips.push(`${dict.concierge.slotChips.category}: ${categoryLabel(dict, categories, draft.categoryId)}`);
  }
  if (draft.pickup !== undefined && draft.pickup.label !== '') {
    chips.push(`${dict.concierge.slotChips.pickup}: ${draft.pickup.label}`);
  }
  if (draft.destination !== undefined && draft.destination.label !== '') {
    chips.push(`${dict.concierge.slotChips.destination}: ${draft.destination.label}`);
  }
  if (draft.urgency !== undefined) {
    chips.push(`${dict.concierge.slotChips.urgency}: ${urgencyLabel(dict, draft.urgency)}`);
  }
  if (chips.length === 0) return null;
  return (
    <div className="flex flex-wrap gap-sm" aria-label={dict.concierge.title}>
      {chips.map((chip) => (
        <StatusChip key={chip} label={chip} tone="info" />
      ))}
    </div>
  );
}

/** show_offer_comparison — links to the request's detail page. */
function OfferComparisonCard({
  locale,
  dict,
  requestId,
}: {
  locale: Locale;
  dict: Dictionary;
  requestId?: string;
}) {
  const href =
    requestId === undefined ? `/${locale}/requests` : `/${locale}/requests/${requestId}`;
  return (
    <div className={cardClasses}>
      <h3 className="text-title-medium text-ink-primary dark:text-ink-dark-primary">
        {dict.offers.title}
      </h3>
      <Link
        href={href}
        className="mt-md inline-block rounded-md bg-brand-primary px-lg py-sm text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong"
      >
        {dict.offers.title}
      </Link>
    </div>
  );
}

/**
 * show_sos_card — visual priority over everything else. Emergency numbers
 * come from the bootstrap country pack; labels resolve through
 * dict.concierge.emergencyNumbers by labelKey.
 */
function SosCard({
  dict,
  emergencyNumbers,
}: {
  dict: Dictionary;
  emergencyNumbers: { labelKey: string; number: string }[];
}) {
  const labels = dict.concierge.emergencyNumbers as Record<string, string>;
  return (
    <div className="mt-sm w-full max-w-md rounded-lg border-2 border-error bg-error/10 p-lg dark:border-error-dark dark:bg-error-dark/20">
      <h3 className="text-title-medium text-error dark:text-error-dark">
        {dict.concierge.sosCard.title}
      </h3>
      <p className="mt-xs text-body-medium text-ink-primary dark:text-ink-dark-primary">
        {dict.concierge.sosCard.body}
      </p>
      {emergencyNumbers.length > 0 ? (
        <div className="mt-md flex flex-wrap gap-sm">
          {emergencyNumbers.map((entry) => (
            <a
              key={`${entry.labelKey}-${entry.number}`}
              href={`tel:${entry.number}`}
              className="rounded-md bg-error px-lg py-sm text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:opacity-90 dark:bg-error-dark"
            >
              {labels[entry.labelKey] ? `${labels[entry.labelKey]}: ${entry.number}` : entry.number}
            </a>
          ))}
        </div>
      ) : null}
    </div>
  );
}

/** handoff_to_form — the request continues on the standard form. */
function HandoffCard({ locale, dict }: { locale: Locale; dict: Dictionary }) {
  return (
    <div className={cardClasses}>
      <h3 className="text-title-medium text-ink-primary dark:text-ink-dark-primary">
        {dict.concierge.handoffCard.title}
      </h3>
      <p className="mt-xs text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
        {dict.concierge.handoffCard.body}
      </p>
      <Link
        href={`/${locale}/requests/new`}
        className="mt-md inline-block rounded-md bg-brand-primary px-lg py-sm text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong"
      >
        {dict.concierge.handoffCard.cta}
      </Link>
    </div>
  );
}

export function ConciergeClient({ locale, dict }: { locale: Locale; dict: Dictionary }) {
  const [conversationId, setConversationId] = useState<string | null>(null);
  const [startError, setStartError] = useState<unknown>(null);
  const [startAttempt, setStartAttempt] = useState(0);
  const [messages, setMessages] = useState<ConciergeMessage[]>([]);
  const [stream, setStream] = useState<{ userText: string; assistantText: string } | null>(
    null,
  );
  const [sendError, setSendError] = useState<unknown>(null);
  const [input, setInput] = useState('');

  // Held for the conversation's lifetime (spec: one key per conversation).
  const startKeyRef = useRef<string | null>(null);
  if (startKeyRef.current === null) {
    startKeyRef.current = newIdempotencyKey();
  }
  // One key per sent message: stable while the text is unchanged (retries
  // replay), regenerated after a successful send or when the text changes.
  const messageKeyRef = useRef<{ key: string; text: string } | null>(null);
  const bottomRef = useRef<HTMLDivElement | null>(null);
  // How many persisted messages existed before the in-flight turn started.
  const streamBaseRef = useRef(0);

  const bootstrapQuery = useQuery({
    queryKey: ['bootstrap'],
    queryFn: () => bootstrapRepository.getBootstrap(),
  });
  const categoriesQuery = useQuery({
    queryKey: ['catalog', 'categories'],
    queryFn: () => catalogRepository.getCategories(),
  });

  // Start the conversation once, then watch the message list (the mock
  // patches the assistant message with the server-side draft requestId
  // asynchronously — the subscription picks that up).
  useEffect(() => {
    let cancelled = false;
    let unsubscribe: (() => void) | undefined;
    conciergeRepository
      .startConversation(startKeyRef.current as string)
      .then((conversation) => {
        const off = conciergeRepository.watchMessages(conversation.id, (next) => {
          if (!cancelled) setMessages(next);
        });
        if (cancelled) {
          off();
          return;
        }
        unsubscribe = off;
        setConversationId(conversation.id);
      })
      .catch((e: unknown) => {
        if (!cancelled) setStartError(e);
      });
    return () => {
      cancelled = true;
      unsubscribe?.();
    };
  }, [startAttempt]);

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ block: 'end' });
  }, [messages, stream]);

  const send = async () => {
    const text = input.trim();
    if (conversationId === null || text === '' || stream !== null) return;
    setSendError(null);
    setInput('');
    if (messageKeyRef.current === null || messageKeyRef.current.text !== text) {
      messageKeyRef.current = { key: newIdempotencyKey(), text };
    }
    const key = messageKeyRef.current.key;
    // How many persisted messages existed before this turn. The mock commits
    // the user + assistant pair to the watched list as soon as the turn runs,
    // so during streaming we render only the pre-turn slice plus the live
    // stream bubbles — no duplicates.
    const baseCount = messages.length;
    setStream({ userText: text, assistantText: '' });
    streamBaseRef.current = baseCount;
    try {
      const chunks = conciergeRepository.sendMessage(conversationId, text, key);
      for await (const chunk of chunks) {
        setStream((s) => (s === null ? s : { ...s, assistantText: s.assistantText + chunk }));
      }
      messageKeyRef.current = null;
      setStream(null);
    } catch (e) {
      // Key is kept so retrying the same text replays instead of re-running.
      setSendError(e);
      setStream(null);
    }
  };

  if (startError !== null) {
    return (
      <div className="mx-auto w-full max-w-3xl px-lg py-xxxl">
        <StateBlock
          variant="error"
          errorMessage={errorText(dict, startError)}
          retryLabel={dict.common.retry}
          onRetry={() => {
            setStartError(null);
            setStartAttempt((a) => a + 1);
          }}
        />
      </div>
    );
  }

  if (conversationId === null) {
    return (
      <div className="mx-auto w-full max-w-3xl px-lg py-xxxl">
        <StateBlock variant="loading" />
      </div>
    );
  }

  const categories = categoriesQuery.data ?? [];
  const visibleMessages = stream === null ? messages : messages.slice(0, streamBaseRef.current);
  const latestDraft = [...messages].reverse().find((m) => m.structuredDraft)?.structuredDraft;
  const voiceAvailable = bootstrapQuery.data?.voiceLanguages[locale] === true;
  const voiceKnown = bootstrapQuery.data !== undefined;
  const emergencyNumbers = bootstrapQuery.data?.countryPack.emergencyNumbers ?? [];

  return (
    <div className="mx-auto flex w-full max-w-3xl flex-col px-lg py-xxxl">
      <h1 className="text-headline-medium text-ink-primary dark:text-ink-dark-primary">
        {dict.concierge.title}
      </h1>
      <p className="mt-md text-body-large text-ink-secondary dark:text-ink-dark-secondary">
        {dict.concierge.intro}
      </p>

      {latestDraft !== undefined ? (
        <div className="mt-lg">
          <SlotChips dict={dict} draft={latestDraft} categories={categories} />
        </div>
      ) : null}

      <div className="mt-xl flex flex-col gap-md" aria-live="polite">
        {visibleMessages.length === 0 && stream === null ? (
          <StateBlock
            variant="empty"
            emptyTitle={dict.common.emptyGeneric}
            emptyBody={dict.concierge.intro}
          />
        ) : null}

        {visibleMessages.map((message) =>
          message.role === 'user' ? (
            <UserBubble key={message.id} text={message.text} />
          ) : (
            <div key={message.id} className="flex flex-col items-start">
              <AssistantBubble text={message.text} />
              {message.proposedAction === 'show_sos_card' ? (
                <SosCard dict={dict} emergencyNumbers={emergencyNumbers} />
              ) : null}
              {message.proposedAction === 'show_publish_card' &&
              message.structuredDraft !== undefined ? (
                <PublishCard
                  locale={locale}
                  dict={dict}
                  draft={message.structuredDraft}
                  categoryName={
                    message.structuredDraft.categoryId === undefined
                      ? ''
                      : categoryLabel(dict, categories, message.structuredDraft.categoryId)
                  }
                />
              ) : null}
              {message.proposedAction === 'show_offer_comparison' ? (
                <OfferComparisonCard
                  locale={locale}
                  dict={dict}
                  requestId={message.structuredDraft?.requestId}
                />
              ) : null}
              {message.proposedAction === 'handoff_to_form' ? (
                <HandoffCard locale={locale} dict={dict} />
              ) : null}
            </div>
          ),
        )}

        {stream !== null ? (
          <>
            <UserBubble text={stream.userText} />
            {stream.assistantText === '' ? (
              <div className="flex justify-start">
                <p className="rounded-lg border border-outline bg-surface-raised px-md py-sm text-body-medium text-ink-secondary dark:border-outline-dark dark:bg-surface-dark-raised dark:text-ink-dark-secondary">
                  {dict.concierge.thinking}
                </p>
              </div>
            ) : (
              <AssistantBubble text={stream.assistantText} />
            )}
          </>
        ) : null}
        <div ref={bottomRef} />
      </div>

      {sendError !== null ? (
        <p role="alert" className="mt-md text-body-medium text-error dark:text-error-dark">
          {errorText(dict, sendError)}
        </p>
      ) : null}

      <form
        className="mt-xl flex flex-col gap-sm"
        onSubmit={(e) => {
          e.preventDefault();
          void send();
        }}
      >
        <div className="flex gap-sm">
          <input
            type="text"
            value={input}
            onChange={(e) => setInput(e.target.value)}
            placeholder={dict.concierge.inputPlaceholder}
            disabled={stream !== null}
            className={inputClasses}
          />
          <button
            type="submit"
            disabled={stream !== null || input.trim() === ''}
            className="rounded-md bg-brand-primary px-xl py-md text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong disabled:opacity-50"
          >
            {dict.concierge.send}
          </button>
          {voiceKnown && voiceAvailable ? (
            // Voice route is not built yet — the entry point stays disabled
            // with a tooltip instead of linking to a 404.
            <button
              type="button"
              disabled
              title={dict.comingSoon.title}
              aria-label={`${dict.concierge.voice.label} — ${dict.comingSoon.title}`}
              className="rounded-md border border-outline px-md py-md text-label-large text-ink-secondary disabled:opacity-50 dark:border-outline-dark dark:text-ink-dark-secondary"
            >
              {dict.concierge.voice.label}
            </button>
          ) : null}
        </div>
        {voiceKnown && !voiceAvailable ? (
          <p className="text-body-small text-ink-secondary dark:text-ink-dark-secondary">
            {dict.concierge.voice.pidginFallback}
          </p>
        ) : null}
      </form>
    </div>
  );
}
