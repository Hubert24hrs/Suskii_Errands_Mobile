// Per-country OTP routing from country packs: public.countries.config.server.sms_providers
// holds an ordered provider list for each live or beta country.

export interface CountryRoute {
  countryCode: string;
  callingCode: string;
  providers: string[];
}

export interface RouteSource {
  load(): Promise<CountryRoute[]>;
}

export function normalisePhoneDigits(phone: string): string {
  return phone.replace(/[^0-9]/g, "");
}

/** Longest calling-code prefix wins, so a future "1" and "1876" cannot collide. */
export function routeFor(phoneDigits: string, routes: CountryRoute[]): CountryRoute | null {
  let best: CountryRoute | null = null;
  for (const route of routes) {
    if (
      phoneDigits.startsWith(route.callingCode) &&
      (best === null || route.callingCode.length > best.callingCode.length)
    ) {
      best = route;
    }
  }
  return best;
}

interface CountryRow {
  code: string;
  calling_code: string;
  config: { server?: { sms_providers?: unknown } } | null;
}

export function routesFromRows(rows: CountryRow[]): CountryRoute[] {
  return rows.map((row) => {
    const configured = row.config?.server?.sms_providers;
    const providers = Array.isArray(configured)
      ? configured.filter((p): p is string => typeof p === "string" && p !== "")
      : [];
    return { countryCode: row.code, callingCode: row.calling_code, providers };
  });
}

/** Caches routes for a short time: OTP bursts should not each hit the database. */
export class CachedRouteSource implements RouteSource {
  private cached: { routes: CountryRoute[]; expiresAt: number } | null = null;

  constructor(
    private readonly fetchRows: () => Promise<CountryRow[]>,
    private readonly ttlMs = 60_000,
    private readonly now: () => number = Date.now,
  ) {}

  async load(): Promise<CountryRoute[]> {
    if (this.cached && this.cached.expiresAt > this.now()) return this.cached.routes;
    const routes = routesFromRows(await this.fetchRows());
    this.cached = { routes, expiresAt: this.now() + this.ttlMs };
    return routes;
  }
}
