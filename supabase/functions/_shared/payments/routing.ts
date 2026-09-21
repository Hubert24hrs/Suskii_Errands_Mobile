// Per-country payment routing from country packs: `public.countries.config.server` holds the
// ordered provider list, the same shape `sms_providers` already uses.
//
// REPORT §3.2 sets the policy this implements: route by method and amount band, and fail over
// between Flutterwave and Paystack on an outage. The band matters commercially — Paystack's
// Nigerian card pricing is capped at ₦2,000 while Flutterwave's 2% is not, so above roughly
// ₦100,000 the cheaper rail changes. Bands are **config**, not constants: the numbers in the
// country packs are `[V]` as of the research date and will move.

export interface AmountBand {
  /** Inclusive minimum in minor units. */
  fromMinor: number;
  providers: string[];
}

export interface CountryPaymentRoute {
  countryCode: string;
  /** Used when no method or band matches. */
  providers: string[];
  /** Keyed by method: `card`, `bank_transfer`, `mobile_money`. */
  byMethod: Record<string, string[]>;
  /** Ordered ascending by `fromMinor`. */
  bands: AmountBand[];
  payoutProviders: string[];
}

export function routeFor(
  countryCode: string,
  routes: CountryPaymentRoute[],
): CountryPaymentRoute | null {
  return routes.find((r) => r.countryCode === countryCode) ?? null;
}

/**
 * The order to try, most specific first: an amount band beats a method, which beats the country
 * default. Duplicates are removed but order is kept, so a provider named by a band is tried first
 * and still acts as the fallback for the ones after it.
 */
export function providersFor(
  route: CountryPaymentRoute,
  options: { method?: string; amountMinor?: number },
): string[] {
  const ordered: string[] = [];
  if (typeof options.amountMinor === "number") {
    const band = [...route.bands]
      .sort((a, b) => b.fromMinor - a.fromMinor)
      .find((b) => options.amountMinor! >= b.fromMinor);
    if (band) ordered.push(...band.providers);
  }
  if (options.method && route.byMethod[options.method]) {
    ordered.push(...route.byMethod[options.method]);
  }
  ordered.push(...route.providers);
  return [...new Set(ordered)];
}

interface CountryRow {
  code: string;
  config:
    | {
      server?: {
        payment_providers?: unknown;
        payment_providers_by_method?: unknown;
        payment_amount_bands?: unknown;
        payout_providers?: unknown;
      };
    }
    | null;
}

function stringList(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((v): v is string => typeof v === "string") : [];
}

export function routesFromRows(rows: CountryRow[]): CountryPaymentRoute[] {
  return rows.map((row) => {
    const server = row.config?.server ?? {};
    const byMethod: Record<string, string[]> = {};
    const rawByMethod = server.payment_providers_by_method;
    if (rawByMethod && typeof rawByMethod === "object" && !Array.isArray(rawByMethod)) {
      for (const [method, value] of Object.entries(rawByMethod as Record<string, unknown>)) {
        const list = stringList(value);
        if (list.length > 0) byMethod[method] = list;
      }
    }

    const bands: AmountBand[] = [];
    const rawBands = server.payment_amount_bands;
    if (Array.isArray(rawBands)) {
      for (const entry of rawBands) {
        if (!entry || typeof entry !== "object") continue;
        const band = entry as { from_minor?: unknown; providers?: unknown };
        const providers = stringList(band.providers);
        if (typeof band.from_minor === "number" && providers.length > 0) {
          bands.push({ fromMinor: band.from_minor, providers });
        }
      }
      bands.sort((a, b) => a.fromMinor - b.fromMinor);
    }

    return {
      countryCode: row.code,
      providers: stringList(server.payment_providers),
      byMethod,
      bands,
      payoutProviders: stringList(server.payout_providers),
    };
  });
}
