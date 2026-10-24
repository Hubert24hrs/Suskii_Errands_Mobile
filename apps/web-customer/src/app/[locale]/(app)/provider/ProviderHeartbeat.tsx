'use client';

import { useEffect } from 'react';
import { useQuery } from '@tanstack/react-query';
import { providerRepository } from '@/lib/repositories';

/** Inside the two-minute matching window with room for one missed tick. */
const INTERVAL_MS = 45_000;

/**
 * While the provider is online, their position goes to the server: matching
 * only considers a position younger than two minutes, so without this an
 * online provider is never told about a request. Only while a provider page
 * is open — the browser gives no location in the background.
 */
export function ProviderHeartbeat() {
  const home = useQuery({ queryKey: ['provider', 'home'], queryFn: () => providerRepository.getHomeSummary() });
  const online = home.data?.online ?? false;

  useEffect(() => {
    if (!online || typeof navigator === 'undefined' || !navigator.geolocation) return;
    const tick = () =>
      navigator.geolocation.getCurrentPosition(
        (p) =>
          void providerRepository
            .reportPosition({ latitude: p.coords.latitude, longitude: p.coords.longitude }, p.coords.accuracy)
            .catch(() => undefined),
        () => undefined,
        { enableHighAccuracy: false, timeout: 15_000, maximumAge: 30_000 },
      );
    tick();
    const timer = setInterval(tick, INTERVAL_MS);
    return () => clearInterval(timer);
  }, [online]);

  return null;
}
