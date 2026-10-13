// The directory over the admin people functions. Search is by exact id, phone
// suffix or name prefix (admin_user_search) and needs four characters: a browse
// of every account is a directory dump, so an empty search lists nobody.
// Organisations, members and vehicles are read through their tables, which
// RLS scopes to the officer's countries.

import { AppError, ErrorCodes } from '@/mocks/errors';
import type { DirectoryFilter, DirectoryKind } from '@/mocks/repositories';
import type {
  ManagedBusiness,
  ManagedProvider,
  ManagedStatus,
  ManagedUser,
  ManagedVehicle,
  ManagedWorker,
  SuspensionRecord,
  TrustLevel,
  VerificationStatus,
} from '@/mocks/types';

import { SupabaseAdminRepo } from './base';
import { SupabaseGateway, type Row } from './gateway';

type DirectoryEntity =
  | ManagedUser
  | ManagedProvider
  | ManagedBusiness
  | ManagedWorker
  | ManagedVehicle;

const MIN_SEARCH = 4;
const DAY_MS = 86_400_000;

function suspensionOf(row: Row | null | undefined): SuspensionRecord | undefined {
  const until = SupabaseGateway.asOptionalTimestamp(row?.['suspended_until']);
  if (!until || until.getTime() <= Date.now()) return undefined;
  return {
    reason: String(row?.['suspension_reason_key'] ?? ''),
    at: until,
    until,
  };
}

function statusOf(suspension: SuspensionRecord | undefined): ManagedStatus {
  return suspension ? 'suspended' : 'active';
}

function matches(entity: DirectoryEntity, filter?: DirectoryFilter): boolean {
  if (filter?.country && 'country' in entity && entity.country !== filter.country) return false;
  if (filter?.status && entity.status !== filter.status) return false;
  return true;
}

export class SupabaseDirectoryRepository extends SupabaseAdminRepo {
  async listUsers(filter?: DirectoryFilter): Promise<ManagedUser[]> {
    const rows = await this.search(filter);
    return rows
      .map((row): ManagedUser => ({
        id: String(row['user_id']),
        name: String(row['display_name'] ?? ''),
        country: String(row['country_code'] ?? ''),
        status: 'active',
        verificationStatus: row['customer_verification'] as VerificationStatus,
        joinedAt: SupabaseGateway.asTimestamp(row['created_at']),
      }))
      .filter((u) => matches(u, filter));
  }

  async listProviders(filter?: DirectoryFilter): Promise<ManagedProvider[]> {
    const rows = await this.search(filter);
    const providers = await this.providerRows(rows.map((r) => r['user_id']));
    return rows
      .filter((row) => providers.has(String(row['user_id'])))
      .map((row) => this.provider(row, providers.get(String(row['user_id']))!))
      .filter((p) => matches(p, filter));
  }

  async listBusinesses(filter?: DirectoryFilter): Promise<ManagedBusiness[]> {
    const rows = await this.gw.selectList(
      'organizations',
      'id, legal_name, registration_masked, country_code, verification_status, suspended_until, suspension_reason_key, created_at',
      {
        prefixColumn: 'legal_name',
        prefixValue: filter?.query?.trim(),
        column: filter?.country ? 'country_code' : undefined,
        value: filter?.country,
        orderBy: 'created_at',
        ascending: false,
        limit: 100,
      },
    );
    const members = await this.gw.selectList('organization_members', 'organization_id, user_id, status', {
      inColumn: 'organization_id',
      inValues: rows.map((r) => r['id']),
    });
    return rows.map((row) => this.business(row, members)).filter((b) => matches(b, filter));
  }

  async listWorkers(filter?: DirectoryFilter): Promise<ManagedWorker[]> {
    const members = await this.gw.selectList(
      'organization_members',
      'organization_id, user_id, role, status',
      { orderBy: 'created_at', ascending: false, limit: 200 },
    );
    const workers = await this.workers(members);
    const q = filter?.query?.trim().toLowerCase();
    return workers.filter(
      (w) => matches(w, filter) && (!q || w.name.toLowerCase().startsWith(q)),
    );
  }

  async listVehicles(filter?: DirectoryFilter): Promise<ManagedVehicle[]> {
    const rows = await this.gw.selectList(
      'vehicles',
      'id, organization_id, owner_user_id, type, plate_masked, documents_status, created_at',
      { orderBy: 'created_at', ascending: false, limit: 200 },
    );
    const q = filter?.query?.trim().toLowerCase();
    return rows
      .map((row) => this.vehicle(row))
      .filter((v) => matches(v, filter) && (!q || v.plate.toLowerCase().includes(q)));
  }

  async getUser(id: string): Promise<ManagedUser> {
    const row = SupabaseAdminRepo.first(await this.gw.rpcRows('admin_user_summary', { p_user_id: id }));
    return {
      id,
      name: String(row['display_name'] ?? ''),
      country: String(row['country_code'] ?? ''),
      status: 'active',
      trustLevel: (row['trust_level'] as TrustLevel | null) ?? undefined,
      verificationStatus: row['customer_verification'] as VerificationStatus,
      jobsCount: Number(row['requests'] ?? 0),
      joinedAt: SupabaseGateway.asTimestamp(row['created_at']),
    };
  }

  async getProvider(id: string): Promise<ManagedProvider> {
    const row = SupabaseAdminRepo.first(await this.gw.rpcRows('admin_user_summary', { p_user_id: id }));
    const providers = await this.providerRows([id]);
    const provider = providers.get(id);
    if (!provider) throw new AppError(ErrorCodes.notFound);
    return {
      ...this.provider(row, provider),
      trustLevel: (row['trust_level'] as TrustLevel | null) ?? undefined,
      completedJobs: Number(row['jobs_as_provider'] ?? 0),
    };
  }

  async getBusiness(id: string): Promise<ManagedBusiness> {
    const summary = SupabaseAdminRepo.first(
      await this.gw.rpcRows('admin_organization_summary', { p_organization_id: id }),
    );
    const row = await this.gw.selectSingle(
      'organizations',
      'id, legal_name, registration_masked, country_code, verification_status, suspended_until, suspension_reason_key, created_at',
      'id',
      id,
    );
    const members = await this.gw.selectList('organization_members', 'organization_id, user_id, status', {
      column: 'organization_id',
      value: id,
    });
    return this.business({ ...summary, ...(row ?? {}), id }, members);
  }

  async getWorker(id: string): Promise<ManagedWorker> {
    const members = await this.gw.selectList('organization_members', 'organization_id, user_id, role, status', {
      column: 'user_id',
      value: id,
    });
    const worker = (await this.workers(members))[0];
    if (!worker) throw new AppError(ErrorCodes.notFound);
    return worker;
  }

  async getVehicle(id: string): Promise<ManagedVehicle> {
    const row = await this.gw.selectSingle(
      'vehicles',
      'id, organization_id, owner_user_id, type, plate_masked, documents_status, created_at',
      'id',
      id,
    );
    if (!row) throw new AppError(ErrorCodes.notFound);
    return this.vehicle(row);
  }

  /**
   * Suspends a provider, worker or business. The reason is a key and the suspension ends:
   * the backend refuses a suspension without an end date, so a permanent ban is not one call.
   * Customers and vehicles have no suspension in the product.
   */
  async suspendEntity(
    kind: DirectoryKind,
    id: string,
    reason: string,
    idempotencyKey: string,
    days = 30,
  ): Promise<DirectoryEntity> {
    const until = new Date(Date.now() + days * DAY_MS).toISOString();
    if (kind === 'provider' || kind === 'worker') {
      await this.gw.rpc('suspend_provider', {
        p_idempotency_key: idempotencyKey,
        p_user_id: id,
        p_reason_key: reason,
        p_until: until,
      });
      return kind === 'provider' ? this.getProvider(id) : this.getWorker(id);
    }
    if (kind === 'business') {
      await this.gw.rpc('suspend_organization', {
        p_idempotency_key: idempotencyKey,
        p_organization_id: id,
        p_reason_key: reason,
        p_until: until,
      });
      return this.getBusiness(id);
    }
    throw new AppError(ErrorCodes.featureUnavailable);
  }

  async unsuspendEntity(
    kind: DirectoryKind,
    id: string,
    idempotencyKey: string,
  ): Promise<DirectoryEntity> {
    if (kind === 'provider' || kind === 'worker') {
      await this.gw.rpc('reinstate_provider', {
        p_idempotency_key: idempotencyKey,
        p_user_id: id,
        p_reason_key: 'reinstated_by_admin',
      });
      return kind === 'provider' ? this.getProvider(id) : this.getWorker(id);
    }
    if (kind === 'business') {
      await this.gw.rpc('reinstate_organization', {
        p_idempotency_key: idempotencyKey,
        p_organization_id: id,
        p_reason_key: 'reinstated_by_admin',
      });
      return this.getBusiness(id);
    }
    throw new AppError(ErrorCodes.featureUnavailable);
  }

  private async search(filter?: DirectoryFilter): Promise<Row[]> {
    const query = filter?.query?.trim() ?? '';
    if (query.length < MIN_SEARCH) return [];
    return this.gw.rpcRows('admin_user_search', { p_query: query, p_limit: 50 });
  }

  private async providerRows(ids: unknown[]): Promise<Map<string, Row>> {
    const rows = await this.gw.selectList(
      'provider_profiles',
      'user_id, organization_id, suspended_until, suspension_reason_key, rating_avg_milli, rating_count',
      { inColumn: 'user_id', inValues: ids },
    );
    return new Map(rows.map((r) => [String(r['user_id']), r]));
  }

  private provider(row: Row, provider: Row): ManagedProvider {
    const suspension = suspensionOf(provider);
    const ratingCount = Number(provider['rating_count'] ?? 0);
    return {
      id: String(row['user_id']),
      name: String(row['display_name'] ?? ''),
      country: String(row['country_code'] ?? ''),
      status: statusOf(suspension),
      verificationStatus: row['provider_verification'] as VerificationStatus,
      rating: ratingCount > 0 ? Number(provider['rating_avg_milli'] ?? 0) / 1000 : undefined,
      businessId: provider['organization_id'] ? String(provider['organization_id']) : undefined,
      joinedAt: SupabaseGateway.asTimestamp(row['created_at']),
      suspension,
    };
  }

  private business(row: Row, members: Row[]): ManagedBusiness {
    const suspension = suspensionOf(row);
    return {
      id: String(row['id'] ?? row['organization_id']),
      name: String(row['legal_name'] ?? ''),
      registrationNumber: String(row['registration_masked'] ?? '—'),
      country: String(row['country_code'] ?? ''),
      status: statusOf(suspension),
      verificationStatus: row['verification_status'] as VerificationStatus,
      providerIds: members
        .filter((m) => String(m['organization_id']) === String(row['id']) && m['status'] === 'active')
        .map((m) => String(m['user_id'])),
      joinedAt: SupabaseGateway.asTimestamp(row['created_at']),
      suspension,
    };
  }

  private async workers(members: Row[]): Promise<ManagedWorker[]> {
    const ids = members.map((m) => m['user_id']);
    const names = await this.names(ids);
    const providers = await this.providerRows(ids);
    const profiles = await this.gw.selectList('profiles', 'user_id, provider_verification', {
      inColumn: 'user_id',
      inValues: ids,
    });
    const verification = new Map(profiles.map((p) => [String(p['user_id']), p['provider_verification']]));
    return members.map((m) => {
      const id = String(m['user_id']);
      const suspension = suspensionOf(providers.get(id));
      return {
        id,
        name: SupabaseAdminRepo.nameOf(names, id),
        businessId: String(m['organization_id']),
        role: String(m['role']),
        status: m['status'] === 'active' ? statusOf(suspension) : 'suspended',
        verificationStatus: (verification.get(id) as VerificationStatus | undefined) ?? 'unverified',
        suspension,
      };
    });
  }

  private vehicle(row: Row): ManagedVehicle {
    const documents = String(row['documents_status'] ?? 'unverified');
    return {
      id: String(row['id']),
      plate: String(row['plate_masked'] ?? '—'),
      type: String(row['type'] ?? ''),
      ownerProviderId: String(row['owner_user_id'] ?? row['organization_id'] ?? ''),
      status: 'active',
      verificationStatus: (documents as VerificationStatus) ?? 'unverified',
    };
  }
}
