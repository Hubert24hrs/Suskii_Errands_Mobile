'use client';
/// <reference types="google.maps" />

// Pick a point by moving the map under a fixed pin; blurred "providers near
// you" areas are drawn as circles, never providers (ADR-0022). Without a Maps
// key it shows a location card instead: "use my location" still sets the
// point, which is what matching needs. Mirrors apps/mobile/lib/app/maps.dart.

import { useEffect, useRef, useState } from 'react';
import type { Dictionary } from '@/lib/i18n/en';
import { googleMapsApiKey, loadGoogleMaps } from '@/lib/maps';
import type { GeoPoint, NearbyArea } from '@/mocks/types';

/** Lagos Island: where the map opens when nothing better is known. */
const DEFAULT_CENTRE: GeoPoint = { latitude: 6.455, longitude: 3.3941 };

function currentPosition(): Promise<GeoPoint | undefined> {
  return new Promise((resolve) => {
    if (typeof navigator === 'undefined' || !navigator.geolocation) return resolve(undefined);
    navigator.geolocation.getCurrentPosition(
      (p) => resolve({ latitude: p.coords.latitude, longitude: p.coords.longitude }),
      () => resolve(undefined),
      { timeout: 10_000, maximumAge: 120_000 },
    );
  });
}

export function PickupMap({
  dict,
  point,
  areas,
  onChange,
}: {
  dict: Dictionary;
  point?: GeoPoint;
  areas: NearbyArea[];
  onChange: (point: GeoPoint) => void;
}) {
  const el = useRef<HTMLDivElement>(null);
  const map = useRef<google.maps.Map | null>(null);
  const circles = useRef<google.maps.Circle[]>([]);
  const onChangeRef = useRef(onChange);
  onChangeRef.current = onChange;
  const [locating, setLocating] = useState(false);
  const [failed, setFailed] = useState(false);
  const [mapError, setMapError] = useState(false);

  useEffect(() => {
    if (!googleMapsApiKey || !el.current) return;
    let cancelled = false;
    loadGoogleMaps()
      .then((maps) => {
        if (cancelled || !el.current) return;
        const start = point ?? DEFAULT_CENTRE;
        const m = new maps.Map(el.current, {
          center: { lat: start.latitude, lng: start.longitude },
          zoom: point ? 16 : 12,
          disableDefaultUI: true,
          zoomControl: true,
          gestureHandling: 'greedy',
          clickableIcons: false,
        });
        m.addListener('idle', () => {
          const c = m.getCenter();
          if (c) onChangeRef.current({ latitude: c.lat(), longitude: c.lng() });
        });
        map.current = m;
      })
      .catch(() => setMapError(true));
    return () => {
      cancelled = true;
    };
    // The map is created once; the point moves it from here on.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => {
    const m = map.current;
    if (!m || !window.google?.maps) return;
    for (const c of circles.current) c.setMap(null);
    circles.current = areas.map(
      (a) =>
        new window.google.maps.Circle({
          map: m,
          center: { lat: a.center.latitude, lng: a.center.longitude },
          // About a grid cell across: an area, never a spot.
          radius: 600,
          strokeWeight: 0,
          fillColor: '#FF6A2E',
          fillOpacity: 0.18,
          clickable: false,
        }),
    );
  }, [areas]);

  async function useMyLocation() {
    setLocating(true);
    setFailed(false);
    const p = await currentPosition();
    setLocating(false);
    if (!p) {
      setFailed(true);
      return;
    }
    onChange(p);
    map.current?.panTo({ lat: p.latitude, lng: p.longitude });
    map.current?.setZoom(16);
  }

  const locate = (
    <button
      type="button"
      onClick={() => void useMyLocation()}
      disabled={locating}
      data-testid="map-use-my-location"
      className="w-fit rounded-md border border-outline px-md py-sm text-label-large text-ink-primary transition-colors duration-normal ease-standard hover:bg-surface-muted disabled:opacity-50 dark:border-outline-dark dark:text-ink-dark-primary dark:hover:bg-surface-dark-muted"
    >
      {dict.map.useMyLocation}
    </button>
  );

  if (!googleMapsApiKey || mapError) {
    return (
      <div
        data-testid="map-fallback"
        className="flex flex-col gap-sm rounded-md border border-outline bg-surface-raised p-lg dark:border-outline-dark dark:bg-surface-dark-raised"
      >
        <p className="text-title-small text-ink-primary dark:text-ink-dark-primary">
          {point ? `📍 ${dict.map.pickupSet}` : dict.map.pickupNeeded}
        </p>
        <p className="text-body-small text-ink-secondary dark:text-ink-dark-secondary">{dict.map.unavailable}</p>
        {locate}
        {failed ? (
          <p role="alert" className="text-body-small text-error dark:text-error-dark">
            {dict.map.locationFailed}
          </p>
        ) : null}
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-sm">
      <div className="relative h-64 overflow-hidden rounded-md border border-outline dark:border-outline-dark">
        <div ref={el} className="h-full w-full" data-testid="map-google" />
        {/* The pin stays in the middle; the map moves under it. */}
        <span
          aria-hidden
          className="pointer-events-none absolute left-1/2 top-1/2 -translate-x-1/2 -translate-y-full text-3xl"
        >
          📍
        </span>
      </div>
      <p className="text-body-small text-ink-secondary dark:text-ink-dark-secondary">{dict.map.pickupHint}</p>
      {locate}
      {failed ? (
        <p role="alert" className="text-body-small text-error dark:text-error-dark">
          {dict.map.locationFailed}
        </p>
      ) : null}
    </div>
  );
}
