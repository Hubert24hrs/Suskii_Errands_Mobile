'use client';

import { useEffect, useState } from 'react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { useQuery } from '@tanstack/react-query';
import { dict } from '@/lib/i18n';
import { jobsRepository } from '@/mocks/repositories';
import type { GeoPoint, JobAdminView } from '@/mocks/types';
import { MoneyText } from '@/components/MoneyText';
import { StateBlock } from '@/components/StateBlock';
import { Timeline } from '@/components/Timeline';
import { can, errorText, formatDateTime, isSessionError, useAdminSession } from '../../_shared';
import { categoryLabel, countryLabel, jobStatusChip, jobStatusLabel } from '../_shared';

function DetailRow({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex flex-wrap justify-between gap-md py-sm">
      <span className="text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
        {label}
      </span>
      <span className="text-body-medium text-ink-primary dark:text-ink-dark-primary">
        {value}
      </span>
    </div>
  );
}

const PLOT_W = 640;
const PLOT_H = 320;
const PLOT_PAD = 36;

/** Normalizes lat/lng into the SVG plot area (map SDK arrives at M9). */
function projector(points: GeoPoint[]): (p: GeoPoint) => { x: number; y: number } {
  let minLat = Math.min(...points.map((p) => p.latitude));
  let maxLat = Math.max(...points.map((p) => p.latitude));
  let minLng = Math.min(...points.map((p) => p.longitude));
  let maxLng = Math.max(...points.map((p) => p.longitude));
  if (maxLat - minLat < 1e-6) {
    minLat -= 0.0005;
    maxLat += 0.0005;
  }
  if (maxLng - minLng < 1e-6) {
    minLng -= 0.0005;
    maxLng += 0.0005;
  }
  return (p) => ({
    x: PLOT_PAD + ((p.longitude - minLng) / (maxLng - minLng)) * (PLOT_W - 2 * PLOT_PAD),
    y: PLOT_H - PLOT_PAD - ((p.latitude - minLat) / (maxLat - minLat)) * (PLOT_H - 2 * PLOT_PAD),
  });
}

function RoutePlot({ job }: { job: JobAdminView }) {
  const all = [...job.routePoints, ...(job.livePosition ? [job.livePosition] : [])];
  if (all.length === 0) return null;
  const project = projector(all);
  const route = job.routePoints.map(project);
  const live = job.livePosition ? project(job.livePosition) : undefined;

  return (
    <svg
      viewBox={`0 0 ${PLOT_W} ${PLOT_H}`}
      role="img"
      aria-label={dict.jobs.detail.mapPlaceholderNote}
      className="w-full rounded-md border border-outline bg-surface-muted dark:border-outline-dark dark:bg-surface-dark-muted"
    >
      {route.length > 1 ? (
        <polyline
          points={route.map((p) => `${p.x},${p.y}`).join(' ')}
          fill="none"
          className="stroke-outline dark:stroke-outline-dark"
          strokeWidth={2}
          strokeDasharray="6 6"
        />
      ) : null}
      {route.length > 0 ? (
        <circle cx={route[0].x} cy={route[0].y} r={7} className="fill-info dark:fill-info-dark" />
      ) : null}
      {route.length > 1 ? (
        <circle
          cx={route[route.length - 1].x}
          cy={route[route.length - 1].y}
          r={7}
          className="fill-success dark:fill-success-dark"
        />
      ) : null}
      {live ? (
        <g>
          <circle cx={live.x} cy={live.y} r={13} className="fill-brand-primary/30 animate-pulse" />
          <circle cx={live.x} cy={live.y} r={6} className="fill-brand-primary" />
        </g>
      ) : null}
    </svg>
  );
}

export function JobDetailClient({ jobId }: { jobId: string }) {
  const router = useRouter();
  const sessionQuery = useAdminSession();
  const role = sessionQuery.data?.admin.role;
  const mayRead = role !== undefined && can(role, 'jobs.read');

  const jobQuery = useQuery({
    queryKey: ['jobs', 'detail', jobId],
    queryFn: () => jobsRepository.getJob(jobId),
    enabled: mayRead,
  });

  // Live position updates ride the watchJob subscription once the baseline
  // fetch succeeded (watchJob throws on unknown ids / missing permission).
  const [live, setLive] = useState<JobAdminView | undefined>(undefined);
  useEffect(() => {
    if (!jobQuery.data) return;
    try {
      return jobsRepository.watchJob(jobId, setLive);
    } catch {
      return;
    }
  }, [jobId, jobQuery.data]);

  useEffect(() => {
    if (jobQuery.error && isSessionError(jobQuery.error)) router.replace('/sign-in');
  }, [jobQuery.error, router]);

  if (sessionQuery.isPending) {
    return <StateBlock variant="loading" />;
  }
  if (!mayRead) {
    return <StateBlock variant="error" errorMessage={dict.errors.ERR_PERMISSION_DENIED} />;
  }

  const job = live ?? jobQuery.data;

  return (
    <div className="flex flex-col gap-xl">
      <div className="flex flex-wrap items-center gap-md">
        <Link
          href="/jobs"
          className="text-label-large text-brand-primary hover:underline dark:text-brand-secondary"
        >
          {dict.common.back}
        </Link>
        <h1 className="text-headline-medium text-ink-primary dark:text-ink-dark-primary">
          {job?.title ?? jobId}
        </h1>
        {job ? jobStatusChip(job.status) : null}
      </div>

      {jobQuery.isPending ? (
        <StateBlock variant="loading" />
      ) : jobQuery.isError ? (
        <StateBlock
          variant="error"
          errorMessage={errorText(jobQuery.error)}
          retryLabel={dict.common.retry}
          onRetry={() => void jobQuery.refetch()}
        />
      ) : job ? (
        <div className="grid grid-cols-1 gap-xl lg:grid-cols-2">
          <section className="rounded-lg border border-outline bg-surface-raised p-xl dark:border-outline-dark dark:bg-surface-dark-raised">
            <h2 className="text-title-large text-ink-primary dark:text-ink-dark-primary">
              {dict.jobs.detail.partiesTitle}
            </h2>
            <div className="mt-md divide-y divide-outline dark:divide-outline-dark">
              <DetailRow label={dict.jobs.columns.customer} value={job.customerName} />
              <DetailRow label={dict.jobs.columns.provider} value={job.providerName ?? '—'} />
              <DetailRow label={dict.jobs.columns.category} value={categoryLabel(job.categoryId)} />
              <DetailRow label={dict.directory.columns.country} value={countryLabel(job.country)} />
              <DetailRow
                label={dict.jobs.detail.offersCountLabel}
                value={String(job.offersCount)}
              />
              <DetailRow label={dict.audit.columns.time} value={formatDateTime(job.createdAt)} />
            </div>
          </section>

          <section className="rounded-lg border border-outline bg-surface-raised p-xl dark:border-outline-dark dark:bg-surface-dark-raised">
            <h2 className="text-title-large text-ink-primary dark:text-ink-dark-primary">
              {dict.jobs.detail.amountsTitle}
            </h2>
            {job.agreedPrice ? (
              <MoneyText
                amountMinor={job.agreedPrice.amountMinor}
                currency={job.agreedPrice.currency}
                className="mt-md block text-headline-medium text-ink-primary dark:text-ink-dark-primary"
              />
            ) : (
              <p className="mt-md text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
                —
              </p>
            )}
            {/* The admin job view carries no price breakdown fields yet —
                only the agreed amount is rendered (reported missing). */}
          </section>

          <section className="rounded-lg border border-outline bg-surface-raised p-xl dark:border-outline-dark dark:bg-surface-dark-raised">
            <h2 className="text-title-large text-ink-primary dark:text-ink-dark-primary">
              {dict.jobs.detail.timelineTitle}
            </h2>
            <div className="mt-md">
              <Timeline
                steps={job.timeline.map((event, i) => ({
                  label: event.note
                    ? `${jobStatusLabel(event.status)} — ${event.note}`
                    : jobStatusLabel(event.status),
                  state: i === job.timeline.length - 1 ? 'current' : 'done',
                  timestamp: formatDateTime(event.at),
                }))}
              />
            </div>
          </section>

          <section className="rounded-lg border border-outline bg-surface-raised p-xl dark:border-outline-dark dark:bg-surface-dark-raised">
            <h2 className="text-title-large text-ink-primary dark:text-ink-dark-primary">
              {dict.nav.jobs}
            </h2>
            <div className="mt-md">
              <RoutePlot job={job} />
            </div>
            <p className="mt-md text-body-small text-ink-secondary dark:text-ink-dark-secondary">
              {dict.jobs.detail.mapPlaceholderNote}
            </p>
            {job.livePosition ? (
              <p className="mt-xs text-body-small text-ink-secondary dark:text-ink-dark-secondary">
                {job.livePosition.latitude.toFixed(5)}, {job.livePosition.longitude.toFixed(5)}
              </p>
            ) : null}
          </section>
        </div>
      ) : null}
    </div>
  );
}
