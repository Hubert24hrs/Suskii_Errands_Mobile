'use client';

import { useEffect, useState } from 'react';
import Link from 'next/link';
import { useQuery } from '@tanstack/react-query';
import type { Dictionary } from '@/lib/i18n/en';
import type { Locale } from '@/lib/i18n';
import {
  catalogRepository,
  chatRepository,
  requestRepository,
  userRepository,
} from '@/mocks/repositories';
import type { ChatMessage, JobRequest } from '@/mocks/types';
import { StateBlock } from '@/components/StateBlock';
import { StatusChip } from '@/components/StatusChip';
import {
  categoryLabel,
  errorText,
  formatDateTime,
  statusLabel,
  statusTone,
} from '../requests/_shared';

/** Short preview for the last message of a thread (labeled for non-text). */
function messagePreview(dict: Dictionary, message: ChatMessage): string {
  if (message.type === 'text' && message.text) return message.text;
  const labels = dict.chat.messageTypes as Record<string, string>;
  switch (message.type) {
    case 'image':
      return labels.photo;
    case 'voice_note':
      return labels.voiceNote ?? message.type;
    case 'location':
      return labels.location;
    case 'offer_card':
      return labels.offerCard;
    case 'system':
      return message.text ?? labels.system;
    default:
      return message.text ?? message.type;
  }
}

export function MessagesClient({ locale, dict }: { locale: Locale; dict: Dictionary }) {
  // No chats-list mock call exists yet — threads are derived from the
  // customer's own jobs (active + history) and per-job watchMessages.
  const jobsQuery = useQuery({
    queryKey: ['requests', 'mine'],
    queryFn: async () => {
      const [active, history] = await Promise.all([
        requestRepository.getMyActiveJobs(),
        requestRepository.getMyRequestHistory({ limit: 50 }),
      ]);
      return [...active, ...history];
    },
  });
  const categoriesQuery = useQuery({
    queryKey: ['catalog', 'categories'],
    queryFn: () => catalogRepository.getCategories(),
  });
  const meQuery = useQuery({
    queryKey: ['user', 'me'],
    queryFn: () => userRepository.getProfile(),
  });
  const meId = meQuery.data?.id;

  const jobs = jobsQuery.data;

  // watchMessages emits the current list immediately, then on every change —
  // one subscription per job keeps previews and unread markers live.
  const [messagesByJob, setMessagesByJob] = useState<Record<string, ChatMessage[]>>({});
  useEffect(() => {
    if (!jobs) return;
    const unsubs = jobs.map((job) =>
      chatRepository.watchMessages(job.id, (messages) =>
        setMessagesByJob((prev) => ({ ...prev, [job.id]: messages })),
      ),
    );
    return () => {
      for (const unsub of unsubs) unsub();
    };
  }, [jobs]);

  const threads = (jobs ?? [])
    .filter((job) => (messagesByJob[job.id]?.length ?? 0) > 0)
    .map((job) => {
      const messages = messagesByJob[job.id];
      const last = messages[messages.length - 1];
      const unread = meId
        ? messages.some((m) => m.senderId !== meId && m.senderId !== 'system' && !m.readAt)
        : false;
      return { job, last, unread };
    })
    .sort((a, b) => b.last.createdAt.getTime() - a.last.createdAt.getTime());

  const categories = categoriesQuery.data ?? [];

  return (
    <div className="mx-auto w-full max-w-5xl px-lg py-xxxl">
      <h1 className="text-headline-medium text-ink-primary dark:text-ink-dark-primary">
        {dict.messages.title}
      </h1>

      <div className="mt-xxl">
        {jobsQuery.isPending ? (
          <StateBlock variant="loading" />
        ) : jobsQuery.isError ? (
          <StateBlock
            variant="error"
            errorMessage={errorText(dict, jobsQuery.error)}
            retryLabel={dict.common.retry}
            onRetry={() => void jobsQuery.refetch()}
          />
        ) : threads.length === 0 ? (
          <StateBlock
            variant="empty"
            emptyTitle={dict.messages.emptyTitle}
            emptyBody={dict.messages.emptyBody}
          />
        ) : (
          <ul className="flex flex-col gap-lg">
            {threads.map(({ job, last, unread }) => (
              <li key={job.id}>
                <Link
                  href={`/${locale}/requests/${job.id}/chat`}
                  className="block rounded-lg border border-outline bg-surface-raised p-xl transition-colors duration-normal ease-standard hover:border-brand-primary dark:border-outline-dark dark:bg-surface-dark-raised dark:hover:border-brand-secondary"
                >
                  <div className="flex flex-wrap items-center justify-between gap-md">
                    <span className="text-label-large text-ink-secondary dark:text-ink-dark-secondary">
                      {categoryLabel(dict, categories, job.categoryId)}
                    </span>
                    <div className="flex items-center gap-md">
                      {unread ? (
                        <span
                          className="inline-block h-2.5 w-2.5 rounded-full bg-brand-primary"
                          aria-hidden="true"
                        />
                      ) : null}
                      {unread ? <span className="sr-only">{dict.messages.unread}</span> : null}
                      <StatusChip
                        label={statusLabel(dict, job.status)}
                        tone={statusTone(job.status)}
                      />
                    </div>
                  </div>
                  <p className="mt-sm line-clamp-1 text-body-large text-ink-primary dark:text-ink-dark-primary">
                    {job.description}
                  </p>
                  <div className="mt-md flex flex-wrap items-center justify-between gap-md">
                    <span className="line-clamp-1 text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
                      {messagePreview(dict, last)}
                    </span>
                    <span className="text-body-small text-ink-secondary dark:text-ink-dark-secondary">
                      {formatDateTime(last.createdAt)}
                    </span>
                  </div>
                </Link>
              </li>
            ))}
          </ul>
        )}
      </div>
    </div>
  );
}
