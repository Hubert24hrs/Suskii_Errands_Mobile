// CatalogRepository over Supabase: the service taxonomy (client-readable
// `service_categories`), the caller's country pack (via `get_bootstrap`,
// which is anon-callable so the pre-login country picker works), and the
// server-computed price band. Mirrors
// packages/suskii_data/lib/src/supabase/supabase_catalog_repository.dart.

import { AppError, ErrorCodes } from '@/mocks/errors';
import type {
  CountryPack,
  PriceBand,
  ServiceCategory,
  Urgency,
} from '@/mocks/types';

import { SupabaseGateway, type Row } from './gateway';
import {
  countryPackFromBootstrap,
  priceBandFromRow,
  serviceCategoryFromRow,
} from './mappers';

/** Explicit column list — a `*` naming an ungranted column fails the query. */
const categoryColumns =
  'id, key, name_key, icon_key, allows_custom, offer_ttl_seconds, ' +
  'max_counter_rounds, proof_requirements';

export class SupabaseCatalogRepository {
  constructor(private readonly gateway: SupabaseGateway) {}

  /** Category key → uuid, built lazily from getCategories. The RPCs that
   * take `category_id` (get_price_band, get_availability_summary,
   * get_category_requirements) want the uuid; everything else on the wire
   * takes the key (`create_request`'s `p_category_key`). */
  private readonly categoryUuids = new Map<string, string>();

  async getCategories(): Promise<ServiceCategory[]> {
    const rows = await this.gateway.selectList(
      'service_categories',
      categoryColumns,
      { column: 'active', value: true, orderBy: 'sort_order' },
    );
    this.categoryUuids.clear();
    for (const row of rows) {
      this.categoryUuids.set(
        row['key'] as string,
        SupabaseGateway.asId(row['id']),
      );
    }
    return rows.map(serviceCategoryFromRow);
  }

  async getCountryPack(countryCode: string): Promise<CountryPack> {
    const bootstrap = (await this.gateway.rpc('get_bootstrap', {
      p_country_code: countryCode,
    })) as Row;
    const pack = bootstrap['country_pack'] as Row | null;
    if (pack == null) {
      // Disabled/unknown country: get_bootstrap returns no pack.
      throw new AppError(ErrorCodes.countryDisabled);
    }
    const cities = await this.gateway.selectList('cities', 'name', {
      column: 'country_code',
      value: countryCode,
    });
    return countryPackFromBootstrap(
      pack,
      cities.map((row) => row['name'] as string),
    );
  }

  /**
   * Server-computed P25/P50/P75 band for a category — advisory only, never
   * used to set prices (ai-design §9). Returns null when the RPC returns no
   * row: the honest "no basis" answer, never a zero band.
   */
  async getPriceBand(options: {
    categoryId: string;
    urgency?: Urgency;
    cityId?: string;
  }): Promise<PriceBand | null> {
    const uuid =
      this.categoryUuids.get(options.categoryId) ??
      (await this.resolveUuid(options.categoryId));
    if (uuid === undefined) return null;
    const rows = (await this.gateway.rpc('get_price_band', {
      p_category_id: uuid,
      p_urgency: options.urgency ?? 'standard',
      p_city_id: options.cityId,
    })) as Row[];
    if (rows.length === 0) return null;
    return priceBandFromRow(rows[0]);
  }

  private async resolveUuid(categoryKey: string): Promise<string | undefined> {
    await this.getCategories();
    return this.categoryUuids.get(categoryKey);
  }
}
