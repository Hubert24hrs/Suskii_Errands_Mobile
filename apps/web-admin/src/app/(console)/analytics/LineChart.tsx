'use client';

// Minimal dependency-free SVG line/area chart for a 30-day analytics
// series: values are normalized into a fixed viewBox, with min/max value
// and first/last date captions rendered as data (no chart lib).

import type { AnalyticsPoint } from '@/mocks/types';

const WIDTH = 600;
const HEIGHT = 200;
const PAD_X = 8;
const PAD_Y = 12;

export function LineChart({ points, label }: { points: AnalyticsPoint[]; label: string }) {
  if (points.length === 0) return null;

  const values = points.map((p) => p.value);
  const min = Math.min(...values);
  const max = Math.max(...values);
  const span = max - min || 1;

  const coords = points.map((p, i) => {
    const x = PAD_X + (i / Math.max(points.length - 1, 1)) * (WIDTH - PAD_X * 2);
    const y = PAD_Y + (1 - (p.value - min) / span) * (HEIGHT - PAD_Y * 2);
    return [x, y] as const;
  });

  const linePath = coords.map(([x, y], i) => `${i === 0 ? 'M' : 'L'}${x.toFixed(1)},${y.toFixed(1)}`).join(' ');
  const areaPath = `${linePath} L${coords[coords.length - 1][0].toFixed(1)},${HEIGHT - PAD_Y} L${coords[0][0].toFixed(1)},${HEIGHT - PAD_Y} Z`;

  const formatValue = (v: number) =>
    new Intl.NumberFormat('en-GB', { maximumFractionDigits: 2 }).format(v);

  return (
    <figure className="flex flex-col gap-sm" aria-label={label}>
      <svg
        viewBox={`0 0 ${WIDTH} ${HEIGHT}`}
        role="img"
        aria-label={label}
        className="w-full rounded-md border border-outline bg-surface-raised dark:border-outline-dark dark:bg-surface-dark-raised"
        preserveAspectRatio="none"
      >
        <path d={areaPath} className="fill-brand-primary/10" />
        <path
          d={linePath}
          fill="none"
          className="stroke-brand-primary"
          strokeWidth={2}
          strokeLinejoin="round"
          strokeLinecap="round"
        />
      </svg>
      <figcaption className="flex flex-wrap justify-between gap-md text-body-small text-ink-secondary dark:text-ink-dark-secondary">
        <span>{points[0].date}</span>
        <span>
          {formatValue(min)} – {formatValue(max)}
        </span>
        <span>{points[points.length - 1].date}</span>
      </figcaption>
    </figure>
  );
}
