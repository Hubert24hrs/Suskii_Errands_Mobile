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
   * Rows of a table, at once and again on every refresh (see `refreshes`):
   * the project publishes no table changes, by design (ADR-0009, contracts
   * rule 9), so a broadcast on one of `topics` says "look again" and the
   * timer covers whatever no broadcast announces. `distinct` (the default)
   * calls back only when the rows differ; a caller that uses the read as a
   * trigger and reloads something else turns it off.
   */
  watchRows(
    table: string,
    columns: string,
    onChange: (rows: Row[]) => void,
    options: SelectListOptions & {
      filterColumn?: string;
      filterValue?: unknown;
      topics?: string[];
      everyMs?: number;
      distinct?: boolean;
    } = {},
  ): Unsubscribe {
    let last: string | undefined;
    const distinct = options.distinct ?? true;
    return this.refreshes(async () => {
      const rows = await this.selectList(table, columns, options);
      const encoded = JSON.stringify(rows);
      if (distinct && encoded === last) return;
      last = encoded;
      onChange(rows);
    }, options);
  }

  /**
   * Runs `read` at once, on any broadcast on `topics`, on each (re)join of
   * one (what was missed while away), when the tab is shown again, and every
   * `everyMs` regardless: a broadcast is a courtesy, never a guarantee. One
   * read at a time; ticks during a read fold into one more. A failed read
   * waits for the next tick. A topic the caller may not join is refused by
   * `private.may_join_topic` and the timer still runs.
   */
  refreshes(
    read: () => Promise<void>,
    { topics = [], everyMs = 15_000 }: { topics?: string[]; everyMs?: number } = {},
  ): Unsubscribe {
    let active = true;
    let reading = false;
    let again = false;
    const run = async (): Promise<void> => {
      if (!active) return;
      if (reading) {
        again = true;
        return;
      }
      reading = true;
      try {
        do {
          again = false;
          try {
            await read();
          } catch {
            // The next tick retries.
          }
        } while (again && active);
      } finally {
        reading = false;
      }
    };
    void run();
    const timer = setInterval(() => void run(), everyMs);
    const onVisible = () => {
      if (document.visibilityState === 'visible') void run();
    };
    const hasDocument = typeof document !== 'undefined';
    if (hasDocument) document.addEventListener('visibilitychange', onVisible);
    const leaves = topics.map((topic) =>
      this.listen(topic, { onMessage: () => void run(), onJoined: () => void run() }),
    );
    return () => {
      active = false;
      clearInterval(timer);
      if (hasDocument) document.removeEventListener('visibilitychange', onVisible);
      for (const leave of leaves) leave();
    };
  }

  /**
   * One channel per topic, shared by everything on this page that uses it:
   * supabase-js hands back the existing channel for a topic, and a second
   * `subscribe()` on it throws, so a job screen's refresh and its location
   * broadcasts must share one join.
   */
  private readonly topics = new Map<
    string,
    {
      channel: ReturnType<SupabaseClient['channel']>;
      listeners: Set<(event: string, payload: Record<string, unknown>) => void>;
      joined: Set<() => void>;
      ready: Promise<void>;
      refs: number;
    }
  >();

  /** Joins `topic` (private, ADR-0009) or shares the join; returns the call that leaves. */
  private listen(
    topic: string,
    handlers: {
      onMessage?: (event: string, payload: Record<string, unknown>) => void;
      onJoined?: () => void;
    } = {},
  ): Unsubscribe {
    let entry = this.topics.get(topic);
    if (!entry) {
      const listeners = new Set<(event: string, payload: Record<string, unknown>) => void>();
      const joined = new Set<() => void>();
      let markReady: () => void = () => {};
      const ready = new Promise<void>((resolve) => (markReady = resolve));
      const channel = this.client
        .channel(topic, { config: { private: true } })
        .on('broadcast', { event: '*' }, (message: { event?: string; payload?: unknown }) => {
          const payload = message.payload;
          if (payload === null || typeof payload !== 'object') return;
          for (const listener of [...listeners]) {
            listener(message.event ?? '', payload as Record<string, unknown>);
          }
        })
        .subscribe((status) => {
          if (status !== 'SUBSCRIBED') return;
          markReady();
          for (const onJoined of [...joined]) onJoined();
        });
      entry = { channel, listeners, joined, ready, refs: 0 };
      this.topics.set(topic, entry);
    }
    const current = entry;
    current.refs += 1;
    if (handlers.onMessage) current.listeners.add(handlers.onMessage);
    if (handlers.onJoined) current.joined.add(handlers.onJoined);
    let left = false;
    return () => {
      if (left) return;
      left = true;
      if (handlers.onMessage) current.listeners.delete(handlers.onMessage);
      if (handlers.onJoined) current.joined.delete(handlers.onJoined);
      current.refs -= 1;
      if (current.refs === 0 && this.topics.get(topic) === current) {
        this.topics.delete(topic);
        void this.client.removeChannel(current.channel);
      }
    };
  }

  /**
   * Calls onMessage with the payload of every `event` broadcast on the private
   * Realtime `topic` (ADR-0009). Authorised by the realtime.messages policies;
   * nothing is read from a table.
   */
  watchBroadcast(
    topic: string,
    event: string,
    onMessage: (payload: Record<string, unknown>) => void,
  ): Unsubscribe {
    return this.listen(topic, {
      onMessage: (received, payload) => {
        if (received === event) onMessage(payload);
      },
    });
  }

  /**
   * Uploads into a private bucket at `path`. The bucket's policy checks the
   * path's first folder, so callers build it the way the policy reads it.
   */
  async uploadBinary(bucket: string, path: string, body: Blob, contentType: string): Promise<void> {
    try {
      const { error } = await this.client.storage
        .from(bucket)
        .upload(path, body, { contentType, upsert: false });
      if (error) throw error;
    } catch (error) {
      throw mapSupabaseError(error);
    }
  }

  /** Topics joined to send on, held for the next send. */
  private readonly sending = new Set<string>();

  /**
   * Sends one `event` on the private Realtime `topic` (ADR-0009), keeping the
   * join for the next send; the realtime.messages policies authorise it.
   */
  async sendBroadcast(topic: string, event: string, payload: Record<string, unknown>): Promise<void> {
    if (!this.sending.has(topic)) {
      this.sending.add(topic);
      this.listen(topic);
    }
    const entry = this.topics.get(topic)!;
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      // A refused or unreachable join must not leave the caller waiting for ever.
      await Promise.race([
        entry.ready,
        new Promise<never>((_, reject) => {
          timer = setTimeout(() => reject(new Error('TIMED_OUT')), 10_000);
        }),
      ]);
    } finally {
      clearTimeout(timer);
    }
    await entry.channel.send({ type: 'broadcast', event, payload });
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
