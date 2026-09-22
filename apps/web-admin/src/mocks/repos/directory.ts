// Directory repository: managed users / providers / businesses / workers /
// vehicles, with suspend/unsuspend (reason required, audit-logged).

import { AppError, ErrorCodes } from '../errors';
import type {
  ManagedBusiness,
  ManagedProvider,
  ManagedStatus,
  ManagedUser,
  ManagedVehicle,
  ManagedWorker,
  SuspensionRecord,
} from '../types';
import { MockRepo } from './base';

export type DirectoryKind = 'user' | 'provider' | 'business' | 'worker' | 'vehicle';

export interface DirectoryFilter {
  country?: string;
  status?: ManagedStatus;
  query?: string;
}

type DirectoryEntity =
  | ManagedUser
  | ManagedProvider
  | ManagedBusiness
  | ManagedWorker
  | ManagedVehicle;

function matches(entity: DirectoryEntity, filter?: DirectoryFilter): boolean {
  if (!filter) return true;
  if (filter.country && 'country' in entity && entity.country !== filter.country) {
    return false;
  }
  if (filter.status && entity.status !== filter.status) return false;
  if (filter.query) {
    const q = filter.query.toLowerCase();
    const haystack = [
      'name' in entity ? entity.name : '',
      'plate' in entity ? entity.plate : '',
      'phone' in entity ? entity.phone : '',
    ]
      .join(' ')
      .toLowerCase();
    if (!haystack.includes(q)) return false;
  }
  return true;
}

export class MockDirectoryRepository extends MockRepo {
  private collection(kind: DirectoryKind): Record<string, DirectoryEntity> {
    switch (kind) {
      case 'user': return this.db.users;
      case 'provider': return this.db.providers;
      case 'business': return this.db.businesses;
      case 'worker': return this.db.workers;
      case 'vehicle': return this.db.vehicles;
    }
  }

  private list(kind: DirectoryKind, filter?: DirectoryFilter): DirectoryEntity[] {
    this.requirePermission('directory.read');
    return Object.values(this.collection(kind)).filter((e) => matches(e, filter));
  }

  private get(kind: DirectoryKind, id: string): DirectoryEntity {
    this.requirePermission('directory.read');
    const entity = this.collection(kind)[id];
    if (!entity) throw new AppError(ErrorCodes.unknown);
    return entity;
  }

  listUsers(filter?: DirectoryFilter): Promise<ManagedUser[]> {
    return this.gate().then(() => this.list('user', filter) as ManagedUser[]);
  }
  listProviders(filter?: DirectoryFilter): Promise<ManagedProvider[]> {
    return this.gate().then(() => this.list('provider', filter) as ManagedProvider[]);
  }
  listBusinesses(filter?: DirectoryFilter): Promise<ManagedBusiness[]> {
    return this.gate().then(() => this.list('business', filter) as ManagedBusiness[]);
  }
  listWorkers(filter?: DirectoryFilter): Promise<ManagedWorker[]> {
    return this.gate().then(() => this.list('worker', filter) as ManagedWorker[]);
  }
  listVehicles(filter?: DirectoryFilter): Promise<ManagedVehicle[]> {
    return this.gate().then(() => this.list('vehicle', filter) as ManagedVehicle[]);
  }

  getUser(id: string): Promise<ManagedUser> {
    return this.gate().then(() => this.get('user', id) as ManagedUser);
  }
  getProvider(id: string): Promise<ManagedProvider> {
    return this.gate().then(() => this.get('provider', id) as ManagedProvider);
  }
  getBusiness(id: string): Promise<ManagedBusiness> {
    return this.gate().then(() => this.get('business', id) as ManagedBusiness);
  }
  getWorker(id: string): Promise<ManagedWorker> {
    return this.gate().then(() => this.get('worker', id) as ManagedWorker);
  }
  getVehicle(id: string): Promise<ManagedVehicle> {
    return this.gate().then(() => this.get('vehicle', id) as ManagedVehicle);
  }

  /** Suspend any directory entity; a reason is mandatory and audit-logged. */
  async suspendEntity(
    kind: DirectoryKind,
    id: string,
    reason: string,
    idempotencyKey: string,
  ): Promise<DirectoryEntity> {
    await this.gate();
    const admin = this.requirePermission('directory.suspend');
    if (!reason.trim()) throw new AppError(ErrorCodes.unknown, { details: 'reason required' });
    return this.idempotent(`directory.suspend:${kind}:${id}`, idempotencyKey, reason, () => {
      const entity = this.collection(kind)[id];
      if (!entity) throw new AppError(ErrorCodes.unknown);
      if (entity.status === 'suspended') throw new AppError(ErrorCodes.invalidState);
      const suspension: SuspensionRecord = {
        reason,
        byAdminId: admin.id,
        at: this.now(),
      };
      entity.status = 'suspended';
      entity.suspension = suspension;
      this.audit('directory.suspend', `${kind}/${id}`, reason);
      return entity;
    });
  }

  async unsuspendEntity(
    kind: DirectoryKind,
    id: string,
    idempotencyKey: string,
  ): Promise<DirectoryEntity> {
    await this.gate();
    this.requirePermission('directory.suspend');
    return this.idempotent(`directory.unsuspend:${kind}:${id}`, idempotencyKey, '', () => {
      const entity = this.collection(kind)[id];
      if (!entity) throw new AppError(ErrorCodes.unknown);
      if (entity.status !== 'suspended') throw new AppError(ErrorCodes.invalidState);
      entity.status = 'active';
      delete entity.suspension;
      this.audit('directory.unsuspend', `${kind}/${id}`);
      return entity;
    });
  }
}
