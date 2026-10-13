// Thin wrapper over the supabase-js client for the admin console, mirroring
// apps/web-customer/src/lib/supabase/gateway.ts and its contracts-v1 conventions:
//
// * RPC arguments are passed by name; null/undefined values are omitted.
// * Column lists are always explicit — several tables grant columns, not rows.
// * Every failure leaves as AppError via mapSupabaseError.
// * `numeric` arrives as a JSON string — use asMinorUnits, never casts.
//
// Every admin function requires an aal2 session (private.has_admin_role), so the
// session repository's TOTP step is what makes any of this answer.

import { createClient, type SupabaseClient } from '@supabase/supabase-js';

import { mapSupabaseError } from './errors';

export type Row = Record<string, unknown>;
export type Unsubscribe = () => void;

export interface SelectListOptions {
  column?: string;
  value?: unknown;
  inColumn?: string;
  inValues?: unknown[];
  /** Case-insensitive prefix match (`ilike 'value%'`). */
  prefixColumn?: string;
  prefixValue?: string;
  orderBy?: string;
  ascending?: boolean;
  limit?: number;
}

export class SupabaseGateway {
  private constructor(
    private readonly client: SupabaseClient,
    private readonly functionsUrl: string,
  ) {}

  /** A gateway when the env config is present, else null (mocks stay on). */
  static fromEnv(): SupabaseGateway | null {
    const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
    const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
    if (!url || !anonKey) return null;
    // Deployed, functions live under the project URL; a local run may serve them apart.
    const functionsUrl =
      process.env.NEXT_PUBLIC_SUPABASE_FUNCTIONS_URL ?? `${url.replace(/\/$/, '')}/functions/v1`;
    return new SupabaseGateway(createClient(url, anonKey), functionsUrl);
  }

  get auth(): SupabaseClient['auth'] {
    return this.client.auth;
  }

  /** The JWT payload of the current session, decoded locally (no network). */
  async claims(): Promise<Record<string, unknown> | null> {
    const {
      data: { session },
    } = await this.client.auth.getSession();
    if (!session) return null;
    const payload = session.access_token.split('.')[1];
    if (!payload) return null;
    const base64 = payload.replace(/-/g, '+').replace(/_/g, '/');
    const padded = base64 + '='.repeat((4 - (base64.length % 4)) % 4);
    try {
      return JSON.parse(atob(padded)) as Record<string, unknown>;
    } catch {
      return null;
    }
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

  /** An RPC that returns a set of rows. */
  async rpcRows(fn: string, args: Record<string, unknown> = {}): Promise<Row[]> {
    const data = await this.rpc(fn, args);
    return Array.isArray(data) ? (data as Row[]) : [];
  }

  /** Reads a single row, or null when no row matches (or RLS hides it). */
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
        if ((options.inValues ?? []).length === 0) return [];
        query = query.in(options.inColumn, options.inValues as string[]);
      }
      if (options.prefixColumn !== undefined && options.prefixValue) {
        // Escape the LIKE wildcards so a search for "50%" means fifty percent.
        const escaped = options.prefixValue.replace(/[\\%_]/g, (c) => `\\${c}`);
        query = query.ilike(options.prefixColumn, `${escaped}%`);
      }
      if (options.orderBy !== undefined) {
        query = query.order(options.orderBy, { ascending: options.ascending ?? true });
      }
      if (options.limit !== undefined) query = query.limit(options.limit);
      const { data, error } = await query;
      if (error) throw error;
      return (data ?? []) as unknown as Row[];
    } catch (error) {
      throw mapSupabaseError(error);
    }
  }

  /** Calls an Edge Function with the signed-in user's token. */
  async invoke(name: string, body: Record<string, unknown>): Promise<Row> {
    try {
      const {
        data: { session },
      } = await this.client.auth.getSession();
      const response = await fetch(`${this.functionsUrl}/${name}`, {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          authorization: `Bearer ${session?.access_token ?? ''}`,
        },
        body: JSON.stringify(body),
      });
      const json = (await response.json().catch(() => ({}))) as Row;
      if (!response.ok) {
        const code = (json['error'] as Row | undefined)?.['code'];
        throw { message: typeof code === 'string' ? code : '', code: String(response.status) };
      }
      return json;
    } catch (error) {
      throw mapSupabaseError(error);
    }
  }

  /**
   * Calls onMessage with every broadcast on a private Realtime topic (ADR-0009). The tables
   * stay the truth; a listener refetches rather than trusting the payload.
   */
  watchBroadcast(topic: string, onMessage: (payload: Row) => void): Unsubscribe {
    const channel = this.client
      .channel(topic, { config: { private: true } })
      .on('broadcast', { event: '*' }, (message: { payload?: unknown }) => {
        const payload = message.payload;
        onMessage(payload !== null && typeof payload === 'object' ? (payload as Row) : {});
      })
      .subscribe();
    return () => {
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

  /** A decimal for display only (averages, ratios) — never money. */
  static asDecimal(value: unknown): number {
    if (typeof value === 'number') return value;
    if (typeof value === 'string') return Number.parseFloat(value);
    return 0;
  }

  static asTimestamp(value: unknown): Date {
    return new Date(String(value));
  }

  static asOptionalTimestamp(value: unknown): Date | undefined {
    return value === null || value === undefined ? undefined : new Date(String(value));
  }
}
