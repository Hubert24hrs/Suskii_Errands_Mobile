'use client';

// Emergency SOS during a job, as the mobile app offers it on the request and
// tracking screens: confirm, then `raise_sos` with the current location; the
// server alerts operations, the security partner and trusted contacts.

import { useEffect, useRef, useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import type { Dictionary } from '@/lib/i18n/en';
import { bootstrapRepository, isAppError, safetyRepository } from '@/lib/repositories';
import { newIdempotencyKey } from '@/lib/idempotency';
import type { GeoPoint, SosAlert } from '@/mocks/types';
import { Modal } from './Modal';

function currentPoint(): Promise<GeoPoint | undefined> {
  return new Promise((resolve) => {
    if (typeof navigator === 'undefined' || !navigator.geolocation) return resolve(undefined);
    navigator.geolocation.getCurrentPosition(
      (p) => resolve({ latitude: p.coords.latitude, longitude: p.coords.longitude }),
      () => resolve(undefined),
      { enableHighAccuracy: true, timeout: 8_000, maximumAge: 30_000 },
    );
  });
}

export function SosButton({ jobId, dict }: { jobId: string; dict: Dictionary }) {
  const t = dict.sos;
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [active, setActive] = useState<SosAlert>();
  const [error, setError] = useState<string>();
  // One alert per press: a retry after a failure replays it, never raises a second.
  const key = useRef<string>(undefined);
  const bootstrap = useQuery({ queryKey: ['bootstrap'], queryFn: () => bootstrapRepository.getBootstrap() });
  const numbers = bootstrap.data?.countryPack.emergencyNumbers ?? [];
  const labels = dict.concierge.emergencyNumbers as Record<string, string>;

  useEffect(() => safetyRepository.watchActiveSos(jobId, setActive), [jobId]);

  async function send() {
    setBusy(true);
    setError(undefined);
    key.current ??= newIdempotencyKey();
    try {
      const alert = await safetyRepository.triggerSos({ jobId, idempotencyKey: key.current, location: await currentPoint() });
      key.current = undefined;
      setActive(alert);
    } catch (e) {
      const table = dict.errors as Record<string, string>;
      setError(isAppError(e) ? (table[e.code] ?? dict.errors.ERR_INTERNAL) : dict.errors.ERR_INTERNAL);
    } finally {
      setBusy(false);
    }
  }

  return (
    <>
      <button
        type="button"
        data-testid="sos-button"
        onClick={() => setOpen(true)}
        className="rounded-md bg-error px-xl py-sm text-label-large text-white transition-colors duration-normal ease-standard hover:opacity-90 dark:bg-error-dark"
      >
        {active ? t.activeTitle : t.cta}
      </button>
      <Modal open={open} onClose={() => setOpen(false)} title={active ? t.activeTitle : t.title} closeLabel={dict.common.close}>
        <div className="flex flex-col gap-md" data-testid="sos-sheet">
          <p className="text-body-medium text-ink-primary dark:text-ink-dark-primary">{active ? t.activeBody : t.confirmBody}</p>
          {!active ? (
            <button
              type="button"
              data-testid="sos-send"
              disabled={busy}
              onClick={() => void send()}
              className="rounded-md bg-error px-xl py-sm text-label-large text-white disabled:opacity-50 dark:bg-error-dark"
            >
              {t.send}
            </button>
          ) : null}
          {error ? (
            <p role="alert" className="text-body-small text-error dark:text-error-dark">
              {error}
            </p>
          ) : null}
          {numbers.length > 0 ? (
            <div className="flex flex-col gap-xs">
              <span className="text-label-large text-ink-primary dark:text-ink-dark-primary">{t.emergencyNumbers}</span>
              <ul className="flex flex-col gap-xs text-body-medium">
                {numbers.map((n) => (
                  <li key={`${n.labelKey}-${n.number}`} className="text-ink-primary dark:text-ink-dark-primary">
                    {labels[n.labelKey] ?? n.labelKey}: <span className="select-all font-semibold">{n.number}</span>
                  </li>
                ))}
              </ul>
            </div>
          ) : null}
        </div>
      </Modal>
    </>
  );
}
