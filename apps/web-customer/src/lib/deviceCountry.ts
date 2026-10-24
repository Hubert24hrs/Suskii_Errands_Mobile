// The country somebody is in, for a new account. Nobody picks one any more
// (owner, 2026-10-24): a customer uses the country they are in. Mirrors
// apps/mobile/lib/app/device_country.dart; a browser has no SIM, so the time
// zone (which the operating system sets from the network) and the language
// region are the signals.

import { catalogRepository } from './repositories';

/** The countries with a country pack. Whether one is open is the server's answer. */
export const SERVED_COUNTRIES = ['NG', 'KE', 'GH', 'ZA', 'UG'] as const;

/** The launch country, used when nothing names a served one. */
export const FALLBACK_COUNTRY = 'NG';

const ZONE_COUNTRIES: Record<string, string> = {
  'Africa/Lagos': 'NG',
  'Africa/Nairobi': 'KE',
  'Africa/Accra': 'GH',
  'Africa/Johannesburg': 'ZA',
  'Africa/Kampala': 'UG',
};

function served(code: string | null | undefined): string | null {
  const upper = code?.trim().toUpperCase();
  return upper && (SERVED_COUNTRIES as readonly string[]).includes(upper) ? upper : null;
}

/** Time zone first, then the first language tag whose region is served. */
export function countryFromSignals(timeZone: string | undefined, languages: readonly string[]): string | null {
  const byZone = served(timeZone ? ZONE_COUNTRIES[timeZone] : null);
  if (byZone) return byZone;
  for (const tag of languages) {
    const region = served(tag.split('-')[1]);
    if (region) return region;
  }
  return null;
}

export function detectBrowserCountry(): string | null {
  if (typeof window === 'undefined') return null;
  let timeZone: string | undefined;
  try {
    timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone;
  } catch {
    timeZone = undefined;
  }
  return countryFromSignals(timeZone, navigator.languages ?? [navigator.language]);
}

/** The detected country while the server serves it, else the launch country:
 * the server ignores a sign-up country that is not open, and an email sign-up
 * has no phone to fall back on. */
export async function resolveSignUpCountry(): Promise<string> {
  const detected = detectBrowserCountry();
  if (!detected || detected === FALLBACK_COUNTRY) return FALLBACK_COUNTRY;
  try {
    const pack = await catalogRepository.getCountryPack(detected);
    return pack.countryCode === detected && pack.status !== 'disabled' ? detected : FALLBACK_COUNTRY;
  } catch {
    return FALLBACK_COUNTRY;
  }
}
