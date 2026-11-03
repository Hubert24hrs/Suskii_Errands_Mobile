// The service catalogue and Ask Suskii usage, in the demo (20261103120100, -120200). The real
// console calls the admin_* functions of the same names; these keep their rules: no delete, a
// reason for every switch, a second factor for every change, and the free allowance shared by
// everybody without an override.

import { AppError, ErrorCodes } from '../errors';
import type {
  AiUsageSummary,
  AiUserUsage,
  CatalogueService,
  ServiceInput,
} from '../types';
import { MockRepo } from './base';

const SEED: ReadonlyArray<[string, string, string, string, number, number, number]> = [
  ['errands_delivery', 'Errands & delivery', 'Pick up, drop off or run an errand across town.', 'package', 14, 3, 9],
  ['shopping', 'Shopping', 'Groceries, market runs and store purchases, bought and brought to you.', 'basket', 11, 2, 7],
  ['cleaning_laundry', 'Cleaning & laundry', 'Home cleaning, washing and ironing.', 'sparkle', 6, 1, 4],
  ['document_delivery', 'Document delivery', 'Documents picked up and delivered, signed for on arrival.', 'document', 5, 0, 3],
  ['plumbing', 'Plumbing', 'Leaks, pipes, taps and water systems.', 'plumbing', 3, 1, 2],
  ['custom', 'Something else', 'Describe what you need if it is not listed.', 'magic', 2, 0, 0],
];

function seedServices(now: Date): CatalogueService[] {
  return SEED.map(([key, name, description, iconKey, requests, open, providers], i) => ({
    id: `svc-${key}`,
    key,
    active: true,
    displayNames: { en: name },
    descriptions: { en: description },
    iconKey,
    requiresVehicle: key === 'errands_delivery' || key === 'shopping',
    allowsCustom: key === 'custom',
    sortOrder: key === 'custom' ? 900 : (i + 1) * 10,
    requestCount: requests,
    openRequestCount: open,
    providerCount: providers,
    updatedAt: now,
  }));
}

const reasonOk = (reason: string) => reason.trim().length >= 3 && reason.trim().length <= 300;

export class MockServicesRepository extends MockRepo {
  private services: CatalogueService[] | null = null;

  private get all(): CatalogueService[] {
    this.services ??= seedServices(this.now());
    return this.services;
  }

  async listServices(): Promise<CatalogueService[]> {
    await this.gate();
    this.requirePermission('services.read');
    return [...this.all].sort((a, b) => a.sortOrder - b.sortOrder || a.key.localeCompare(b.key));
  }

  async saveService(input: ServiceInput, idempotencyKey: string): Promise<CatalogueService> {
    await this.gate();
    this.requireSensitive('services.manage');
    return this.idempotent('saveService', idempotencyKey, JSON.stringify(input), () => {
      if (!/^[a-z0-9_]{2,40}$/.test(input.key) || (input.displayNames.en ?? '').trim().length < 2) {
        throw new AppError('ERR_INVALID_ARGUMENT');
      }
      const existing = this.all.find((s) => s.key === input.key);
      if (existing) {
        existing.displayNames = input.displayNames;
        existing.descriptions = input.descriptions;
        existing.iconKey = input.iconKey ?? existing.iconKey;
        existing.requiresVehicle = input.requiresVehicle ?? existing.requiresVehicle;
        existing.updatedAt = this.now();
        this.audit('service.updated', input.key);
        return existing;
      }
      const created: CatalogueService = {
        id: `svc-${input.key}`,
        key: input.key,
        active: true,
        displayNames: input.displayNames,
        descriptions: input.descriptions,
        iconKey: input.iconKey ?? 'magic',
        requiresVehicle: input.requiresVehicle ?? false,
        allowsCustom: false,
        sortOrder: Math.max(...this.all.filter((s) => s.key !== 'custom').map((s) => s.sortOrder)) + 10,
        requestCount: 0,
        openRequestCount: 0,
        providerCount: 0,
        updatedAt: this.now(),
      };
      this.all.push(created);
      this.audit('service.created', input.key);
      return created;
    });
  }

  async setServiceActive(key: string, active: boolean, reason: string): Promise<void> {
    await this.gate();
    this.requireSensitive('services.manage');
    if (!reasonOk(reason)) throw new AppError('ERR_INVALID_ARGUMENT');
    const service = this.all.find((s) => s.key === key);
    if (!service) throw new AppError(ErrorCodes.notFound);
    if (service.active !== active) {
      service.active = active;
      service.updatedAt = this.now();
      this.audit(active ? 'service.activated' : 'service.deactivated', key, reason);
    }
  }
}

export class MockAiUsageRepository extends MockRepo {
  private budget = { dailyMicros: 2_000_000, monthlyMicros: 25_000_000 };
  private tiers: Record<string, { daily: number; monthly: number }> = { free: { daily: 10, monthly: 150 } };
  private enabled = true;
  private people: AiUserUsage[] = [
    { userId: 'user-ada', displayName: 'Ada Okafor', countryCode: 'NG', requests: 41, failed: 1, tokens: 118_400, costMicros: 236_900, usedToday: 9, dailyLimit: 10, usedThisMonth: 41, monthlyLimit: 150, credits: 0 },
    { userId: 'user-chidi', displayName: 'Chidi Eze', countryCode: 'NG', requests: 17, failed: 0, tokens: 44_100, costMicros: 88_300, usedToday: 2, dailyLimit: 10, usedThisMonth: 17, monthlyLimit: 150, credits: 0 },
    { userId: 'user-bola', displayName: 'Bola Adeyemi', countryCode: 'NG', requests: 6, failed: 0, tokens: 15_900, costMicros: 31_800, usedToday: 0, dailyLimit: 10, usedThisMonth: 6, monthlyLimit: 150, credits: 0 },
  ];

  async getSummary(from: string, to: string): Promise<AiUsageSummary> {
    await this.gate();
    this.requirePermission('aiUsage.read');
    const cost = this.people.reduce((sum, p) => sum + p.costMicros, 0);
    const requests = this.people.reduce((sum, p) => sum + p.requests, 0);
    const failed = this.people.reduce((sum, p) => sum + p.failed, 0);
    const now = this.now();
    return {
      from,
      to,
      totals: {
        requests,
        completed: requests - failed,
        failed,
        released: 3,
        tokensIn: 162_000,
        tokensOut: 16_400,
        tokensThought: 0,
        costMicros: cost,
        users: this.people.length,
        avgCostPerUserMicros: Math.floor(cost / this.people.length),
      },
      byDay: [{ day: to, requests, failed, tokensIn: 162_000, tokensOut: 16_400, costMicros: cost, users: this.people.length }],
      byModel: [{ modelId: 'gemini-3.5-flash', location: 'europe-west2', requests, tokensIn: 162_000, tokensOut: 16_400, costMicros: cost }],
      budget: {
        ...this.budget,
        spentTodayMicros: 61_200,
        spentThisMonthMicros: cost,
        dayExceeded: 61_200 >= this.budget.dailyMicros,
        monthExceeded: cost >= this.budget.monthlyMicros,
        dayResetsAt: new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() + 1)),
        monthResetsAt: new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 1)),
      },
      enabled: this.enabled,
      tiers: this.tiers,
      pricingVerifiedAt: '2026-11-03',
    };
  }

  async listUsers(_from: string, _to: string, sort: 'cost' | 'near_limit'): Promise<AiUserUsage[]> {
    await this.gate();
    this.requirePermission('aiUsage.people');
    const near = (p: AiUserUsage) => Math.max(p.usedToday / (p.dailyLimit || 1), p.usedThisMonth / (p.monthlyLimit || 1));
    return [...this.people].sort((a, b) => (sort === 'cost' ? b.costMicros - a.costMicros : near(b) - near(a)));
  }

  private person(userId: string): AiUserUsage {
    const person = this.people.find((p) => p.userId === userId);
    if (!person) throw new AppError(ErrorCodes.notFound);
    return person;
  }

  async setQuota(userId: string, daily: number | null, monthly: number | null, expiresAt: Date | null, reason: string): Promise<void> {
    await this.gate();
    this.requireSensitive('aiUsage.manage');
    if (!reasonOk(reason) || (expiresAt && expiresAt <= this.now())) throw new AppError('ERR_INVALID_ARGUMENT');
    const p = this.person(userId);
    p.dailyLimit = daily ?? this.tiers.free.daily;
    p.monthlyLimit = monthly ?? this.tiers.free.monthly;
    p.overrideExpiresAt = daily === null && monthly === null ? undefined : (expiresAt ?? undefined);
    this.audit('ai.quota_set', userId, reason);
  }

  async grantCredits(idempotencyKey: string, userId: string, credits: number, reason: string): Promise<void> {
    await this.gate();
    this.requireSensitive('aiUsage.manage');
    await this.idempotent('grantCredits', idempotencyKey, `${userId}:${credits}`, () => {
      if (!reasonOk(reason) || credits < 1 || credits > 1000) throw new AppError('ERR_INVALID_ARGUMENT');
      this.person(userId).credits += credits;
      this.audit('ai.credits_granted', userId, reason);
    });
  }

  async setSuspension(userId: string, until: Date | null, reason: string): Promise<void> {
    await this.gate();
    this.requireSensitive('aiUsage.manage');
    if (!reasonOk(reason) || (until && until <= this.now())) throw new AppError('ERR_INVALID_ARGUMENT');
    this.person(userId).suspendedUntil = until ?? undefined;
    this.audit(until ? 'ai.suspended' : 'ai.suspension_lifted', userId, reason);
  }

  async setBudget(dailyMicros: number, monthlyMicros: number, reason: string): Promise<void> {
    await this.gate();
    this.requireSensitive('aiUsage.controls');
    if (!reasonOk(reason) || dailyMicros < 0 || dailyMicros > monthlyMicros) throw new AppError('ERR_INVALID_ARGUMENT');
    this.budget = { dailyMicros, monthlyMicros };
    this.audit('ai.budget_set', 'ai.budget', reason);
  }

  async setTier(tier: string, daily: number, monthly: number, reason: string): Promise<void> {
    await this.gate();
    this.requireSensitive('aiUsage.controls');
    if (!reasonOk(reason) || daily < 0 || daily > monthly) throw new AppError('ERR_INVALID_ARGUMENT');
    this.tiers = { ...this.tiers, [tier]: { daily, monthly } };
    this.audit('ai.tier_set', tier, reason);
  }

  async setEnabled(enabled: boolean, reason: string): Promise<void> {
    await this.gate();
    this.requireSensitive('aiUsage.controls');
    if (!reasonOk(reason)) throw new AppError('ERR_INVALID_ARGUMENT');
    this.enabled = enabled;
    this.audit(enabled ? 'ai.enabled' : 'ai.disabled', 'concierge.text', reason);
  }
}
