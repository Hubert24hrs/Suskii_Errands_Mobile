// Insight & control repositories: config (feature flags / country packs /
// commissions, all behind a propose → second-admin approval flow),
// analytics series, the append-only audit log, and the read-only AI Admin
// Assistant.

import { sleep } from '../behavior';
import { AppError, ErrorCodes } from '../errors';
import type {
  AiAdminMessage,
  AnalyticsMetric,
  AnalyticsSeries,
  AuditLogEntry,
  CommissionConfig,
  ConfigChange,
  CountryPackConfig,
  FeatureFlag,
} from '../types';
import { MockRepo, type Unsubscribe } from './base';

export interface AdminConfig {
  featureFlags: FeatureFlag[];
  countryPacks: CountryPackConfig[];
  commissions: CommissionConfig[];
}

export interface ConfigChangeInput {
  target: ConfigChange['target'];
  targetKey: string;
  summary: string;
  proposedValue: Record<string, unknown>;
}

export class MockConfigRepository extends MockRepo {
  async getConfig(): Promise<AdminConfig> {
    await this.gate();
    this.requirePermission('config.read');
    return {
      featureFlags: Object.values(this.db.featureFlags),
      countryPacks: Object.values(this.db.countryPackConfigs),
      commissions: Object.values(this.db.commissionConfigs),
    };
  }

  async listChanges(status?: ConfigChange['status']): Promise<ConfigChange[]> {
    await this.gate();
    this.requirePermission('config.read');
    return Object.values(this.db.configChanges).filter(
      (c) => !status || c.status === status,
    );
  }

  /**
   * Propose a config change (flag toggle, country-pack edit, commission
   * rate). Sensitive: reauth within 5 min. Nothing applies until a SECOND
   * admin approves.
   */
  async proposeChange(
    input: ConfigChangeInput,
    idempotencyKey: string,
  ): Promise<ConfigChange> {
    await this.gate();
    const admin = this.requireSensitive('config.propose');
    return this.idempotent(
      'config.propose',
      idempotencyKey,
      JSON.stringify(input),
      () => {
        const change: ConfigChange = {
          id: `cc-${globalThis.crypto.randomUUID().slice(0, 8)}`,
          target: input.target,
          targetKey: input.targetKey,
          summary: input.summary,
          proposedValue: input.proposedValue,
          proposedByAdminId: admin.id,
          proposedAt: this.now(),
          status: 'proposed',
        };
        this.db.configChanges[change.id] = change;
        this.audit('config.propose', `${input.target}/${input.targetKey}`, input.summary);
        return change;
      },
    );
  }

  /**
   * Approve a proposed change. Must be a different admin than the proposer
   * (same admin → ERR_INVALID_STATE). Applies the change on approval.
   */
  async approveChange(changeId: string, idempotencyKey: string): Promise<ConfigChange> {
    await this.gate();
    const admin = this.requireSensitive('config.approve');
    return this.idempotent(`config.approve:${changeId}`, idempotencyKey, '', () => {
      const change = this.db.configChanges[changeId];
      if (!change) throw new AppError(ErrorCodes.unknown);
      if (change.status !== 'proposed') throw new AppError(ErrorCodes.alreadyReviewed);
      if (change.proposedByAdminId === admin.id) {
        throw new AppError(ErrorCodes.invalidState, {
          details: 'approver must differ from proposer',
        });
      }
      change.status = 'approved';
      change.decidedByAdminId = admin.id;
      change.decidedAt = this.now();
      this.applyChange(change);
      this.audit('config.approve', `${change.target}/${change.targetKey}`, change.summary);
      return change;
    });
  }

  async rejectChange(
    changeId: string,
    reason: string,
    idempotencyKey: string,
  ): Promise<ConfigChange> {
    await this.gate();
    const admin = this.requireSensitive('config.approve');
    return this.idempotent(`config.reject:${changeId}`, idempotencyKey, reason, () => {
      const change = this.db.configChanges[changeId];
      if (!change) throw new AppError(ErrorCodes.unknown);
      if (change.status !== 'proposed') throw new AppError(ErrorCodes.alreadyReviewed);
      change.status = 'rejected';
      change.decidedByAdminId = admin.id;
      change.decidedAt = this.now();
      this.audit('config.reject', `${change.target}/${change.targetKey}`, reason);
      return change;
    });
  }

  private applyChange(change: ConfigChange): void {
    switch (change.target) {
      case 'feature_flag': {
        const flag = this.db.featureFlags[change.targetKey];
        if (flag && typeof change.proposedValue.enabled === 'boolean') {
          flag.enabled = change.proposedValue.enabled;
        }
        break;
      }
      case 'commission': {
        const commission = this.db.commissionConfigs[change.targetKey];
        const rateBps = change.proposedValue.rateBps;
        if (commission && typeof rateBps === 'number') {
          commission.rateBps = rateBps;
          commission.effectiveFrom = this.now();
        }
        break;
      }
      case 'country_pack': {
        const pack = this.db.countryPackConfigs[change.targetKey];
        if (pack) Object.assign(pack, change.proposedValue);
        break;
      }
    }
  }
}

export class MockAnalyticsRepository extends MockRepo {
  async getSeries(metric: AnalyticsMetric, country: string): Promise<AnalyticsSeries> {
    await this.gate();
    this.requirePermission('analytics.read');
    const series = this.db.analytics.find(
      (s) => s.metric === metric && s.country === country,
    );
    if (!series) throw new AppError(ErrorCodes.unknown);
    return series;
  }
}

export interface AuditFilter {
  actorAdminId?: string;
  actionPrefix?: string;
  target?: string;
}

export class MockAuditRepository extends MockRepo {
  /** Append-only, newest first. Super admin only. */
  async listEntries(filter?: AuditFilter): Promise<AuditLogEntry[]> {
    await this.gate();
    this.requirePermission('audit.read');
    return [...this.db.auditLog]
      .reverse()
      .filter((e) => {
        if (filter?.actorAdminId && e.actorAdminId !== filter.actorAdminId) return false;
        if (filter?.actionPrefix && !e.action.startsWith(filter.actionPrefix)) return false;
        if (filter?.target && e.target !== filter.target) return false;
        return true;
      });
  }

  watchEntries(listener: (entry: AuditLogEntry) => void): Unsubscribe {
    this.requirePermission('audit.read');
    return this.db.auditEvents.subscribe(listener);
  }
}

export class MockAiAdminRepository extends MockRepo {
  async listMessages(): Promise<AiAdminMessage[]> {
    await this.gate();
    this.requirePermission('aiAdmin.use');
    return this.db.aiChat;
  }

  /**
   * Read-only assistant: replies with insights and proposed_action cards
   * that deep-link into console modules. It never mutates domain data —
   * the only writes are the chat transcript itself. onChunk streams the
   * reply body in slices for a typing effect.
   */
  async sendMessage(
    text: string,
    idempotencyKey: string,
    onChunk?: (partialBody: string) => void,
  ): Promise<AiAdminMessage> {
    await this.gate();
    this.requirePermission('aiAdmin.use');
    return this.idempotent('aiAdmin.send', idempotencyKey, text, async () => {
      this.db.aiChat.push({
        id: `ai-${Date.now()}-q`,
        role: 'admin',
        body: text,
        at: this.now(),
      });
      const reply = this.buildInsightReply(text);
      if (onChunk) {
        const step = Math.max(8, Math.floor(reply.body.length / 6));
        for (let i = step; i < reply.body.length + step; i += step) {
          await sleep(Math.min(120, this.behavior.latencyMs / 6));
          onChunk(reply.body.slice(0, i));
        }
      }
      this.db.aiChat.push(reply);
      return reply;
    });
  }

  /** Canned-but-data-driven insight built from the live fixtures. */
  private buildInsightReply(_text: string): AiAdminMessage {
    const ng = this.db.metrics.NG;
    const openDisputes = Object.values(this.db.disputes).filter(
      (d) => d.status === 'open' || d.status === 'in_review',
    ).length;
    const activeSos = Object.values(this.db.sosAlerts).filter(
      (a) => a.status === 'active',
    ).length;
    const awaiting = Object.values(this.db.payments).filter(
      (p) => p.approval.state === 'awaiting_second',
    );
    const flags = Object.values(this.db.referralFlags).filter((f) => f.status === 'open');

    const lines = [
      `NG snapshot: ${ng.dau.toLocaleString('en-NG')} DAU, ${ng.activeJobs} active jobs, ${ng.openDisputes} open disputes.`,
      activeSos > 0
        ? `⚠ ${activeSos} SOS alert is ACTIVE right now — the operations console has the live trail.`
        : 'No active SOS alerts.',
      awaiting.length > 0
        ? `${awaiting.length} withdrawal is awaiting a second approval (e.g. ${awaiting[0].id}, ${awaiting[0].counterpartyName}).`
        : 'No withdrawals awaiting second approval.',
      `${openDisputes} dispute case(s) need attention; ${flags.length} referral flag(s) still open.`,
    ];
    return {
      id: `ai-${Date.now()}-a`,
      role: 'assistant',
      body: lines.join('\n'),
      at: this.now(),
      proposedActions: [
        ...(activeSos > 0
          ? [{ module: '/sos', targetId: 'sos-1', label: 'Open SOS console', rationale: 'Active alert with a live location trail' }]
          : []),
        ...(awaiting.length > 0
          ? [{ module: '/payments', targetId: awaiting[0].id, label: 'Review withdrawal', rationale: 'Two-person approval pending' }]
          : []),
        { module: '/disputes', targetId: 'disp-1', label: 'Open dispute queue', rationale: `${openDisputes} case(s) open or in review` },
      ],
    };
  }
}
