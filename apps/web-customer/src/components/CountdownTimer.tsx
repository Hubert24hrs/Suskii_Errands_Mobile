'use client';

import { useEffect, useState } from 'react';

function remainingMs(deadline: string, clockOffsetMs: number): number {
  return new Date(deadline).getTime() - (Date.now() + clockOffsetMs);
}

export function CountdownTimer({
  deadline,
  clockOffsetMs = 0,
  expiredLabel,
  className,
}: {
  deadline: string;
  clockOffsetMs?: number;
  expiredLabel: string;
  className?: string;
}) {
  const [ms, setMs] = useState(() => remainingMs(deadline, clockOffsetMs));

  useEffect(() => {
    const tick = () => setMs(remainingMs(deadline, clockOffsetMs));
    tick();
    const id = setInterval(tick, 1000);
    return () => clearInterval(id);
  }, [deadline, clockOffsetMs]);

  if (ms <= 0) {
    return <span className={className}>{expiredLabel}</span>;
  }

  const totalSeconds = Math.floor(ms / 1000);
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;

  return (
    <span className={className} role="timer">
      {String(minutes).padStart(2, '0')}:{String(seconds).padStart(2, '0')}
    </span>
  );
}
