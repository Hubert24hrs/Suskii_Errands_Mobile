// Thin wrapper over the supabase-js client that encodes the contracts-v1
// calling conventions in one place, mirroring
// packages/suskii_data/lib/src/supabase/supabase_gateway.dart:
//
// * RPC arguments are passed by name; null/undefined values are omitted,
//   never sent (for several functions null is a meaningful value).
// * Column lists are always explicit — contracts v1 narrows column grants on
//   several tables, and a `*` naming an ungranted column fails the query.
// * Every failure leaves as AppError via mapSupabaseError.
// * `numeric` arrives as a JSON string — use asMinorUnits, never casts.
// * 64-bit ids arrive as JSON numbers that can exceed 2^53 — hold them as
//   opaque strings via asId.

import { createClient, type SupabaseClient } from '@supabase/supabase-js';

import { mapSupabaseError } from './errors';

export type Row = Record<string, unknown>;
export type Unsubscribe = () => void;

export interface SelectListOptions {
  column?: string;
  value?: unknown;
  inColumn?: string;
  inValues?: unknown[];
  ltColumn?: string;
  ltValue?: unknown;
  orderBy?: string;
  ascending?: boolean;
  limit?: number;
}

export class SupabaseGateway {
  private constructor(private readonly client: SupabaseClient) {}

  /** A gateway when the env config is present, else null (mocks stay on). */
  static fromEnv(): SupabaseGateway | null {
    const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
    const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
    if (!url || !anonKey) return null;
    return new SupabaseGateway(createClient(url, anonKey));
  }

  get auth(): SupabaseClient['auth'] {
    return this.client.auth;
  }

  /** The signed-in user's auth id from the local session (no network). */
  async currentAuthUserId(): Promise<string | undefined> {
    const {
      data: { session },
    } = await this.client.auth.getSession();
    return session?.user.id;
  }

  /** Calls an RPC with named arguments, omitting null-valued ones. */
  async rpc(fn: string, args: Record<string, unknown> = {}): Promise<unknown> {
    try {
      const params = Object.fromEntries(
        Object.entries(args).filter(([, v]) => v !== null && v !== undefined),
      );
      const { data, error } = await this.client.rpc(fn, params);
      if (error) throw error;
      return data;
    } catch (error) {
      throw mapSupabaseError(error);
    }
  }

  /** Reads a single row, or null when no row matches. */
  async selectSingle(
    table: string,
    columns: string,
    column: string,
    value: unknown,
  ): Promise<Row | null> {
    try {
      const { data, error } = await this.client
        .from(table)
        .select(columns)
        .eq(column, value as string)
        .maybeSingle();
      if (error) throw error;
      return data as Row | null;
    } catch (error) {
      throw mapSupabaseError(error);
    }
  }

  /** Reads rows with optional filters and an optional ordering. */
  async selectList(
    table: string,
    columns: string,
    options: SelectListOptions = {},
  ): Promise<Row[]> {
    try {
      let query = this.client.from(table).select(columns);
      if (options.column !== undefined) {
        query = query.eq(options.column, options.value as string);
      }
      if (options.inColumn !== undefined) {
        query = query.in(options.inColumn, options.inValues as string[]);
      }
      if (options.ltColumn !== undefined) {
        query = query.lt(options.ltColumn, options.ltValue as string);
      }
      if (options.orderBy !== undefined) {
        query = query.order(options.orderBy, {
          ascending: options.ascending ?? true,
        });
      }
      if (options.limit !== undefined) query = query.limit(options.limit);
      const { data, error } = await query;
      if (error) throw error;
      return (data ?? []) as unknown as Row[];
    } catch (error) {
      throw mapSupabaseError(error);
    }
  }

  /** Row count with an optional equality filter and/or an IS NULL filter. */
  async countRows(
    table: string,
    options: { column?: string; value?: unknown; isNullColumn?: string } = {},
  ): Promise<number> {
    try {
      let query = this.client
        .from(table)
        .select('*', { count: 'exact', head: true });
      if (options.column !== undefined) {
        query = query.eq(options.column, options.value as string);
      }
      if (options.isNullColumn !== undefined) {
        query = query.is(options.isNullColumn, null);
      }
      const { count, error } = await query;
      if (error) throw error;
      return count ?? 0;
    } catch (error) {
      throw mapSupabaseError(error);
    }
  }

  /** Upserts rows, returning the upserted rows. */
  async upsertRows(
    table: string,
    rows: Row[],
    onConflict: string,
    columns = '*',
  ): Promise<Row[]> {
    try {
      const { data, error } = await this.client
        .from(table)
        .upsert(rows, { onConflict })
        .select(columns);
      if (error) throw error;
      return (data ?? []) as unknown as Row[];
    } catch (error) {
      throw mapSupabaseError(error);
    }
  }

  /** Updates rows matching one equality filter, returning the updated rows. */
  async updateRows(
    table: string,
    values: Row,
    column: string,
    value: unknown,
    columns = '*',
  ): Promise<Row[]> {
    try {
      const { data, error } = await this.client
        .from(table)
        .update(values)
        .eq(column, value as string)
        .select(columns);
      if (error) throw error;
      return (data ?? []) as unknown as Row[];
    } catch (error) {
      throw mapSupabaseError(error);
    }
  }

  /**
   * Emits the current rows immediately, then re-fetches on every
   * postgres-changes event for the table (RLS scopes rows server-side).
   * Follows the watch*(onChange) → Unsubscribe convention of the mock layer.
   */
  watchRows(
    table: string,
    columns: string,
    onChange: (rows: Row[]) => void,
    options: SelectListOptions & { filterColumn?: string; filterValue?: unknown } = {},
  ): Unsubscribe {
    let active = true;
    const load = async (): Promise<void> => {
      try {
        const rows = await this.selectList(table, columns, options);
        if (active) onChange(rows);
      } catch {
        // Keep the subscription; the next event retries the fetch.
      }
    };
    void load();
    const filter =
      options.filterColumn !== undefined
        ? `${options.filterColumn}=eq.${String(options.filterValue)}`
        : undefined;
    const channel = this.client
      .channel(`watch:${table}:${filter ?? 'all'}:${Math.random().toString(36).slice(2)}`)
      .on(
        'postgres_changes',
        { event: '*', schema: 'public', table, ...(filter ? { filter } : {}) },
        () => void load(),
      )
      .subscribe();
    return () => {
      active = false;
      void this.client.removeChannel(channel);
    };
  }

  /** Opaque id string — safe for 64-bit ids that exceed 2^53. */
  static asId(value: unknown): string {
    return String(value);
  }

  /** Parses a minor-units integer that may arrive as number or `numeric` string. */
  static asMinorUnits(value: unknown): number {
    if (typeof value === 'number') return Math.trunc(value);
    if (typeof value === 'string') return Number.parseInt(value, 10);
    throw mapSupabaseError(new Error('not a minor-units value'));
  }

  /** Parses a decimal that may arrive as number or a `numeric` string
   * (`rank_offers.score`, rating averages). Display only — never money. */
  static asDecimal(value: unknown): number {
    if (typeof value === 'number') return value;
    if (typeof value === 'string') return Number.parseFloat(value);
    throw mapSupabaseError(new Error('not a decimal value'));
  }

  /** Parses an RFC 3339 / Postgres timestamp with time zone. */
  static asTimestamp(value: unknown): Date {
    return new Date(String(value));
  }
}
