'use client';

import { useEffect, useState } from 'react';
import Link from 'next/link';
import { useQuery } from '@tanstack/react-query';
import type { Dictionary } from '@/lib/i18n/en';
import type { Locale } from '@/lib/i18n';
import { newIdempotencyKey } from '@/lib/idempotency';
import { requestRepository, safetyRepository, trackingRepository } from '@/mocks/repositories';
import type { GeoPoint, JobRequest, JobStatus, TripShare } from '@/mocks/types';
import { CopyButton } from '@/components/CopyButton';
import { StateBlock } from '@/components/StateBlock';
import { StatusChip } from '@/components/StatusChip';
import { errorText, statusLabel, statusTone } from '../../_shared';

/** States in which a job is in contact and live tracking makes sense. */
const TRACKABLE: ReadonlySet<JobStatus> = new Set([
  'paid_held',
  'assigned',
  'en_route',
  'arrived',
  'in_progress',
  'completed_by_provider',
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

const PLOT_W = 640;
const PLOT_H = 360;
const PLOT_PAD = 40;

type PlotPoint = { x: number; y: number };

/** Normalizes lat/lng deltas into the SVG plot area (no map SDK in the mock). */
function projector(points: GeoPoint[]): (p: GeoPoint) => PlotPoint {
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

function LegendDot({ className }: { className: string }) {
  return <span className={`inline-block h-3 w-3 rounded-full ${className}`} aria-hidden="true" />;
}

function TrackPlot({
  job,
  trail,
  dict,
}: {
  job: JobRequest;
  trail: GeoPoint[];
  dict: Dictionary;
}) {
  const pickup = job.pickup.point;
  const destination = job.destination?.point;
  const live = trail.length > 0 ? trail[trail.length - 1] : undefined;

  const all = [pickup, destination, ...trail].filter((p): p is GeoPoint => p !== undefined);
  if (all.length === 0) {
    return (
      <p className="rounded-md border border-outline bg-surface-muted p-xl text-center text-body-medium text-ink-secondary dark:border-outline-dark dark:bg-surface-dark-muted dark:text-ink-dark-secondary">
        {dict.tracking.liveHint}
      </p>
    );
  }
  const project = projector(all);
  const pickupPt = pickup ? project(pickup) : undefined;
  const destinationPt = destination ? project(destination) : undefined;
  const livePt = live ? project(live) : undefined;
  const trailPts = trail.map(project);

  return (
    <div>
      <svg
        viewBox={`0 0 ${PLOT_W} ${PLOT_H}`}
        role="img"
        aria-label={dict.tracking.title}
        className="w-full rounded-md border border-outline bg-surface-muted dark:border-outline-dark dark:bg-surface-dark-muted"
      >
        {pickupPt && destinationPt ? (
          <line
            x1={pickupPt.x}
            y1={pickupPt.y}
            x2={destinationPt.x}
            y2={destinationPt.y}
            className="stroke-outline dark:stroke-outline-dark"
            strokeWidth={2}
            strokeDasharray="6 6"
          />
        ) : null}
        {trailPts.length > 1 ? (
          <polyline
            points={trailPts.map((p) => `${p.x},${p.y}`).join(' ')}
            fill="none"
            className="stroke-brand-primary"
            strokeWidth={3}
            strokeLinecap="round"
            strokeLinejoin="round"
          />
        ) : null}
        {pickupPt ? (
          <circle cx={pickupPt.x} cy={pickupPt.y} r={8} className="fill-info dark:fill-info-dark" />
        ) : null}
        {destinationPt ? (
          <circle
            cx={destinationPt.x}
            cy={destinationPt.y}
            r={8}
            className="fill-success dark:fill-success-dark"
          />
        ) : null}
        {livePt ? (
          <g>
            <circle
              cx={livePt.x}
              cy={livePt.y}
              r={14}
              className="fill-brand-primary/30 animate-pulse"
            />
            <circle cx={livePt.x} cy={livePt.y} r={7} className="fill-brand-primary" />
          </g>
        ) : null}
      </svg>
      <ul className="mt-md flex flex-wrap gap-lg text-body-small text-ink-secondary dark:text-ink-dark-secondary">
        <li className="flex items-center gap-sm">
          <LegendDot className="bg-info dark:bg-info-dark" />
          {dict.tracking.legend.pickup}
        </li>
        <li className="flex items-center gap-sm">
          <LegendDot className="bg-success dark:bg-success-dark" />
          {dict.tracking.legend.destination}
        </li>
        <li className="flex items-center gap-sm">
          <LegendDot className="bg-brand-primary" />
          {dict.tracking.legend.live}
        </li>
      </ul>
    </div>
  );
}

export function TrackClient({
  locale,
  jobId,
  dict,
}: {
  locale: Locale;
  jobId: string;
  dict: Dictionary;
}) {
  const { query, job } = useJob(jobId);

  const active = job !== undefined && TRACKABLE.has(job.status);

  const [trail, setTrail] = useState<GeoPoint[]>([]);
  useEffect(() => {
    if (!active) return;
    setTrail([]);
    return trackingRepository.watchProviderLocation(jobId, (point) =>
      setTrail((prev) => [...prev.slice(-99), point]),
    );
  }, [active, jobId]);

  // One idempotency key per trip-share intent; regenerated after success.
  const [shareKey, setShareKey] = useState(() => newIdempotencyKey());
  const [share, setShare] = useState<TripShare | undefined>(undefined);
  const [shareBusy, setShareBusy] = useState(false);
  const [shareError, setShareError] = useState<string | null>(null);

  const createShare = async () => {
    setShareBusy(true);
    setShareError(null);
    try {
      const result = await safetyRepository.createTripShareLink(jobId, shareKey);
      setShare(result);
      setShareKey(newIdempotencyKey());
    } catch (e) {
      setShareError(errorText(dict, e));
    } finally {
      setShareBusy(false);
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

  return (
    <div className="mx-auto w-full max-w-3xl px-lg py-xxxl">
      <div className="flex flex-wrap items-center justify-between gap-md">
        <h1 className="text-headline-medium text-ink-primary dark:text-ink-dark-primary">
          {dict.tracking.title}
        </h1>
        <StatusChip label={statusLabel(dict, job.status)} tone={statusTone(job.status)} />
      </div>

      {active ? (
        <>
          <p className="mt-md text-body-medium text-ink-secondary dark:text-ink-dark-secondary">
            {dict.tracking.liveHint}
          </p>
          <div className="mt-xxl">
            <TrackPlot job={job} trail={trail} dict={dict} />
          </div>
          <section className="mt-xxl rounded-lg border border-outline bg-surface-raised p-xl dark:border-outline-dark dark:bg-surface-dark-raised">
            {share ? (
              <div className="flex flex-wrap items-center gap-md">
                <span className="min-w-0 flex-1 truncate text-body-medium text-ink-primary dark:text-ink-dark-primary">
                  {share.url}
                </span>
                <CopyButton
                  text={share.url}
                  label={dict.tracking.copyLink}
                  copiedLabel={dict.tracking.linkCopied}
                />
              </div>
            ) : (
              <button
                type="button"
                disabled={shareBusy}
                onClick={() => void createShare()}
                className="rounded-md bg-brand-primary px-xl py-md text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong disabled:opacity-50"
              >
                {dict.tracking.shareTrip}
              </button>
            )}
            {shareError ? (
              <p role="alert" className="mt-sm text-body-small text-error dark:text-error-dark">
                {shareError}
              </p>
            ) : null}
          </section>
          <p className="mt-lg text-body-small text-ink-secondary dark:text-ink-dark-secondary">
            {dict.tracking.noMapNote}
          </p>
        </>
      ) : (
        <div className="mt-xxl">
          <StateBlock
            variant="empty"
            emptyTitle={dict.tracking.title}
            emptyBody={dict.tracking.liveHint}
          />
          <div className="flex justify-center">
            <Link
              href={`/${locale}/requests/${job.id}`}
              className="rounded-md bg-brand-primary px-xl py-sm text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong"
            >
              {dict.common.back}
            </Link>
          </div>
        </div>
      )}
    </div>
  );
}
