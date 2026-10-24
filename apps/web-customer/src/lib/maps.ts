/// <reference types="google.maps" />
// Loads the Google Maps JavaScript API once, on demand (ADR-0022). The key is
// a restricted browser key from NEXT_PUBLIC_GOOGLE_MAPS_API_KEY; without one
// the app shows a location fallback instead of a map.

export const googleMapsApiKey = process.env.NEXT_PUBLIC_GOOGLE_MAPS_API_KEY ?? '';

let loading: Promise<typeof google.maps> | null = null;

export function loadGoogleMaps(): Promise<typeof google.maps> {
  if (!googleMapsApiKey) return Promise.reject(new Error('no maps key'));
  if (typeof window !== 'undefined' && window.google?.maps) {
    return Promise.resolve(window.google.maps);
  }
  loading ??= new Promise((resolve, reject) => {
    const callback = '__suskiiMapsReady';
    (window as unknown as Record<string, () => void>)[callback] = () => resolve(window.google.maps);
    const script = document.createElement('script');
    script.src =
      `https://maps.googleapis.com/maps/api/js?key=${encodeURIComponent(googleMapsApiKey)}` +
      `&v=weekly&loading=async&callback=${callback}`;
    script.async = true;
    script.onerror = () => {
      loading = null;
      reject(new Error('maps failed to load'));
    };
    document.head.appendChild(script);
  });
  return loading;
}
