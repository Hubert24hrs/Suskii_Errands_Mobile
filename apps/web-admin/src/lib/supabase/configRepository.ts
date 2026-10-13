// Configuration through the config-change four eyes, the analytics views, the audit
// log (audit_search) and the AI assistant, which has no backend yet.

import { AppError, ErrorCodes } from '@/mocks/errors';
import type {
  AdminConfig,
  AuditFilter,
  ConfigChangeInput,
  Unsubscribe,
} from '@/mocks/repositories';
import type {
  AiAdminMessage,
  AnalyticsMetric,
  AnalyticsSeries,
  AuditLogEntry,
  CommissionConfig,
  ConfigChange,
  CountryPackConfig,
  FeatureFlag,
} from '@/mocks/types';

import { SupabaseAdminRepo } from './base';
import { SupabaseGateway, type Row } from './gateway';
import { propose } from './proposals';

const CHANGE_STATUS: Record<string, ConfigChange['status']> = {
  pending: 'proposed',
  applied: 'approved',
  rejected: 'rejected',
};

function consoleTarget(row: Row): ConfigChange['target'] {
  const target = String(row['target']);
  if (target === 'country') {
    const proposed = (row['proposed'] ?? {}) as Row;
    return 'commission_rate_bps' in proposed ? 'commission' : 'country_pack';
  }
  return target as ConfigChange['target'];
}

function summarise(row: Row): string {
  const note = row['note'];
  const proposed = (row['proposed'] ?? {}) as Row;
  const diff = Object.entries(proposed)
    .map(([k, v]) => `${k} → ${typeof v === 'object' ? JSON.stringify(v) : String(v)}`)
    .join(', ');
  return typeof note === 'string' && note.trim() !== '' ? `${note} (${diff})` : diff;
}

export class SupabaseConfigRepository extends SupabaseAdminRepo {
  async getConfig(): Promise<AdminConfig> {
    const [flags, countries] = await Promise.all([
      this.gw.selectList('feature_flags', 'key, country_code, enabled, payload', { orderBy: 'key' }),
      this.gw.selectList(
        'countries',
        'code, status, currency_code, commission_rate_bps, config, approved_at, updated_at',
        { orderBy: 'code' },
      ),
    ]);
    const byKey = new Map<string, Row[]>();
    for (const flag of flags) {
      const key = String(flag['key']);
      byKey.set(key, [...(byKey.get(key) ?? []), flag]);
    }
    const featureFlags: FeatureFlag[] = [...byKey.entries()].map(([key, rows]) => {
      const global = rows.find((r) => r['country_code'] === null);
      const payload = (global?.['payload'] ?? rows[0]?.['payload'] ?? {}) as Row;
      return {
        key,
        description: typeof payload['description'] === 'string' ? payload['description'] : key,
        enabled: global ? Boolean(global['enabled']) : false,
        countries: rows
          .filter((r) => r['country_code'] !== null && r['enabled'])
          .map((r) => String(r['country_code'])),
      };
    });
    const countryPacks: CountryPackConfig[] = countries.map((c) => {
      const client = ((c['config'] as Row | null)?.['client'] ?? {}) as Row;
      return {
        country: String(c['code']),
        currency: String(c['currency_code']),
        live: c['status'] === 'live',
        categories: Array.isArray(client['categories']) ? (client['categories'] as string[]) : [],
        supportPhone: typeof client['support_phone'] === 'string' ? client['support_phone'] : '',
      };
    });
    const commissions: CommissionConfig[] = countries.map((c) => ({
      country: String(c['code']),
      rateBps: Number(c['commission_rate_bps'] ?? 0),
      effectiveFrom: SupabaseGateway.asTimestamp(c['approved_at'] ?? c['updated_at']),
    }));
    return { featureFlags, countryPacks, commissions };
  }

  async listChanges(status?: ConfigChange['status']): Promise<ConfigChange[]> {
    const rows = await this.gw.selectList(
      'config_changes',
      'id, target, target_key, country_code, proposed, note, approvals_required, status, requested_by, created_at, decided_at',
      { orderBy: 'created_at', ascending: false, limit: 200 },
    );
    const approvals = await this.gw.selectList('approvals', 'subject_id, approved_by, status, decided_at', {
      column: 'subject_kind',
      value: 'config_change',
    });
    return rows
      .map((row): ConfigChange => {
        const mine = approvals.filter((a) => String(a['subject_id']) === String(row['id']));
        const decider = mine
          .filter((a) => a['approved_by'])
          .sort((a, b) => String(a['decided_at']).localeCompare(String(b['decided_at'])))
          .at(-1);
        return {
          id: String(row['id']),
          target: consoleTarget(row),
          targetKey: String(row['target_key']),
          summary: summarise(row),
          proposedValue: (row['proposed'] ?? {}) as Record<string, unknown>,
          proposedByAdminId: String(row['requested_by']),
          proposedAt: SupabaseGateway.asTimestamp(row['created_at']),
          status: CHANGE_STATUS[String(row['status'])] ?? 'proposed',
          decidedByAdminId:
            row['status'] !== 'pending' && decider ? String(decider['approved_by']) : undefined,
          decidedAt: SupabaseGateway.asOptionalTimestamp(row['decided_at']),
          approvalsRequired: Number(row['approvals_required'] ?? 1),
          approvalsGiven: mine.filter((a) => a['status'] === 'approved').length,
        };
      })
      .filter((c) => !status || c.status === status);
  }

  async proposeChange(input: ConfigChangeInput, idempotencyKey: string): Promise<ConfigChange> {
    await this.requireRecentMfa('config.propose');
    let id: string;
    switch (input.target) {
      case 'feature_flag':
        id = await propose(this.gw, idempotencyKey, 'feature_flag', input.targetKey,
          { enabled: input.proposedValue['enabled'] }, undefined, input.summary);
        break;
      case 'commission':
        id = await propose(this.gw, idempotencyKey, 'country', input.targetKey,
          { commission_rate_bps: input.proposedValue['rateBps'] }, undefined, input.summary);
        break;
      case 'country_pack': {
        const { live, ...rest } = input.proposedValue;
        id = await propose(this.gw, idempotencyKey, 'country', input.targetKey,
          live === undefined ? rest : { ...rest, status: live ? 'live' : 'beta' },
          undefined, input.summary);
        break;
      }
      default:
        id = await propose(this.gw, idempotencyKey, input.target, input.targetKey,
          input.proposedValue, undefined, input.summary);
    }
    const change = (await this.listChanges()).find((c) => c.id === id);
    if (!change) throw new AppError(ErrorCodes.notFound);
    return change;
  }

  async approveChange(changeId: string, idempotencyKey: string): Promise<ConfigChange> {
    await this.requireRecentMfa('config.approve');
    await this.gw.rpc('review_config_change', {
      p_idempotency_key: idempotencyKey,
      p_change_id: changeId,
      p_approve: true,
    });
    return this.change(changeId);
  }

  async rejectChange(
    changeId: string,
    reason: string,
    idempotencyKey: string,
  ): Promise<ConfigChange> {
    await this.requireRecentMfa('config.approve');
    await this.gw.rpc('review_config_change', {
      p_idempotency_key: idempotencyKey,
      p_change_id: changeId,
      p_approve: false,
      p_reason_key: reason,
    });
    return this.change(changeId);
  }

  private async change(changeId: string): Promise<ConfigChange> {
    const change = (await this.listChanges()).find((c) => c.id === changeId);
    if (!change) throw new AppError(ErrorCodes.notFound);
    return change;
  }
}

const DAYS = 30;

function lastDays(): string[] {
  const days: string[] = [];
  const today = new Date();
  for (let i = DAYS - 1; i >= 0; i--) {
    const d = new Date(Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), today.getUTCDate() - i));
    days.push(d.toISOString().slice(0, 10));
  }
  return days;
}

export class SupabaseAnalyticsRepository extends SupabaseAdminRepo {
  /**
   * A metric for one country over the last thirty days, summed from the daily views. Rates
   * are display ratios of two counts, never money. There is no activity view, so daily
   * active users are not available from the backend yet.
   */
  async getSeries(metric: AnalyticsMetric, country: string): Promise<AnalyticsSeries> {
    const days = lastDays();
    const from = days[0];
    const read = async (view: string) =>
      (await this.gw.rpc('analytics_report', { p_view: view, p_from: from, p_limit: 5000 }) as Row[] ?? [])
        .filter((r) => r['country_code'] === country);
    const sum = (rows: Row[], column: string) => {
      const totals = new Map<string, number>();
      for (const row of rows) {
        const day = String(row['day']);
        totals.set(day, (totals.get(day) ?? 0) + Number(row[column] ?? 0));
      }
      return totals;
    };
    const ratio = (top: Map<string, number>, bottom: Map<string, number>) =>
      new Map(days.map((d) => {
        const b = bottom.get(d) ?? 0;
        return [d, b === 0 ? 0 : Math.round(((top.get(d) ?? 0) / b) * 1000) / 10];
      }));

    let values: Map<string, number>;
    let currency = '';
    switch (metric) {
      case 'gmv': {
        const rows = await read('jobs_daily');
        values = sum(rows, 'gmv_minor');
        currency = String(rows[0]?.['currency'] ?? '');
        break;
      }
      case 'jobs_completed':
        values = sum(await read('jobs_daily'), 'jobs_completed');
        break;
      case 'dispute_rate':
        values = ratio(sum(await read('disputes_daily'), 'disputes'), sum(await read('jobs_daily'), 'jobs_created'));
        break;
      case 'offer_acceptance_rate': {
        const offers = await read('offers_daily');
        values = ratio(sum(offers, 'offers_accepted'), sum(offers, 'offers_made'));
        break;
      }
      case 'dau':
        throw new AppError(ErrorCodes.featureUnavailable);
    }
    if (!currency) {
      const pack = await this.gw.selectSingle('countries', 'currency_code', 'code', country);
      currency = String(pack?.['currency_code'] ?? '');
    }
    return {
      metric,
      country,
      currency,
      points: days.map((date) => ({ date, value: values.get(date) ?? 0 })),
    };
  }
}

export class SupabaseAuditRepository extends SupabaseAdminRepo {
  /** Newest first. Reading the log is itself written to the log (audit_search). */
  async listEntries(filter?: AuditFilter): Promise<AuditLogEntry[]> {
    const rows = await this.gw.rpcRows('audit_search', {
      p_limit: 200,
      p_actor_id: filter?.actorAdminId,
      p_action_prefix: filter?.actionPrefix,
      p_target_id: filter?.target?.split('/').at(-1),
    });
    return rows.map((row) => ({
      id: SupabaseGateway.asId(row['id']),
      actorAdminId: row['actor_id'] ? String(row['actor_id']) : '',
      actorName: String(row['actor_name'] ?? row['actor_role'] ?? 'system'),
      action: String(row['action']),
      target: [row['target_table'], row['target_id']].filter((v) => v != null).join('/'),
      reason: row['reason_code'] ? String(row['reason_code']) : undefined,
      at: SupabaseGateway.asTimestamp(row['created_at']),
    }));
  }

  /**
   * No live feed: each read of the log writes an `audit.search` row, so polling would fill
   * the log with its own reads. The page refreshes on demand instead.
   */
  watchEntries(_listener: (entry: AuditLogEntry) => void): Unsubscribe {
    return () => {};
  }
}

export class SupabaseAiAdminRepository extends SupabaseAdminRepo {
  async listMessages(): Promise<AiAdminMessage[]> {
    return [];
  }

  /** The assistant needs the AI service (Vertex AI, GCP billing: client action 1). */
  async sendMessage(
    _text: string,
    _idempotencyKey: string,
    _onChunk?: (partialBody: string) => void,
  ): Promise<AiAdminMessage> {
    throw new AppError(ErrorCodes.featureUnavailable);
  }
}
