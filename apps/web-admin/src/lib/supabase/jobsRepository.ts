// Jobs as the console sees them: requests and jobs through their tables (RLS
// decides which a role may read — everything for a super admin, a ticketed or
// disputed job for support and dispute officers), the timeline from job_events,
// and the route from the trip trail (super admin only, job_trail).

import { AppError, ErrorCodes } from '@/mocks/errors';
import type { JobSearchFilter, Unsubscribe } from '@/mocks/repositories';
import type { GeoPoint, JobAdminView, JobStatus, JobTimelineEvent } from '@/mocks/types';

import { SupabaseAdminRepo, money } from './base';
import { SupabaseGateway, type Row } from './gateway';

const REQUEST_COLUMNS =
  'id, customer_id, country_code, category_id, description, status, created_at, pickup_point, destination_point';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const POLL_MS = 15_000;

function point(value: unknown): GeoPoint | undefined {
  if (value === null || typeof value !== 'object') return undefined;
  const coords = (value as Row)['coordinates'];
  if (!Array.isArray(coords) || coords.length < 2) return undefined;
  return { longitude: Number(coords[0]), latitude: Number(coords[1]) };
}

function actorOf(kind: unknown): JobTimelineEvent['actor'] {
  switch (kind) {
    case 'customer':
    case 'provider':
    case 'admin':
      return kind;
    case 'worker':
      return 'provider';
    default:
      return 'system';
  }
}

export class SupabaseJobsRepository extends SupabaseAdminRepo {
  async searchJobs(filter?: JobSearchFilter): Promise<JobAdminView[]> {
    const text = filter?.text?.trim() ?? '';
    const requests = await this.gw.selectList('requests', REQUEST_COLUMNS, {
      column: UUID.test(text) ? 'id' : filter?.status ? 'status' : filter?.country ? 'country_code' : undefined,
      value: UUID.test(text) ? text : (filter?.status ?? filter?.country),
      orderBy: 'created_at',
      ascending: false,
      limit: 100,
    });
    const views = await this.views(requests, false);
    const q = UUID.test(text) ? '' : text.toLowerCase();
    return views.filter((job) => {
      if (filter?.status && job.status !== filter.status) return false;
      if (filter?.country && job.country !== filter.country) return false;
      if (filter?.customerId && job.customerId !== filter.customerId) return false;
      if (filter?.providerId && job.providerId !== filter.providerId) return false;
      if (q) {
        const haystack = `${job.id} ${job.title} ${job.customerName} ${job.providerName ?? ''}`;
        if (!haystack.toLowerCase().includes(q)) return false;
      }
      return true;
    });
  }

  async getJob(jobId: string): Promise<JobAdminView> {
    const request = await this.gw.selectSingle('requests', REQUEST_COLUMNS, 'id', jobId);
    if (!request) throw new AppError(ErrorCodes.notFound);
    const [view] = await this.views([request], true);
    return view!;
  }

  /** Re-reads the job on a timer: positions are a courtesy stream, the tables are the truth. */
  watchJob(jobId: string, listener: (job: JobAdminView) => void): Unsubscribe {
    let active = true;
    const load = () =>
      this.getJob(jobId)
        .then((job) => {
          if (active) listener(job);
        })
        .catch(() => {});
    void load();
    const timer = setInterval(() => void load(), POLL_MS);
    return () => {
      active = false;
      clearInterval(timer);
    };
  }

  private async views(requests: Row[], detail: boolean): Promise<JobAdminView[]> {
    const ids = requests.map((r) => r['id']);
    const [jobs, offers] = await Promise.all([
      this.gw.selectList('jobs', 'request_id, provider_id, agreed_amount_minor, currency', {
        inColumn: 'request_id',
        inValues: ids,
      }),
      this.gw.selectList('offers', 'id, request_id', { inColumn: 'request_id', inValues: ids }),
    ]);
    const jobOf = new Map(jobs.map((j) => [String(j['request_id']), j]));
    const names = await this.names([
      ...requests.map((r) => r['customer_id']),
      ...jobs.map((j) => j['provider_id']),
    ]);

    return Promise.all(
      requests.map(async (request) => {
        const id = String(request['id']);
        const job = jobOf.get(id);
        const status = request['status'] as JobStatus;
        const description = String(request['description'] ?? '');
        const view: JobAdminView = {
          id,
          title: description.length > 60 ? `${description.slice(0, 57)}…` : description,
          categoryId: String(request['category_id'] ?? ''),
          country: String(request['country_code'] ?? ''),
          customerId: String(request['customer_id']),
          customerName: SupabaseAdminRepo.nameOf(names, request['customer_id']),
          providerId: job?.['provider_id'] ? String(job['provider_id']) : undefined,
          providerName: job?.['provider_id']
            ? SupabaseAdminRepo.nameOf(names, job['provider_id'])
            : undefined,
          status,
          agreedPrice: job?.['agreed_amount_minor'] != null
            ? money(job['agreed_amount_minor'], job['currency'])
            : undefined,
          offersCount: offers.filter((o) => String(o['request_id']) === id).length,
          createdAt: SupabaseGateway.asTimestamp(request['created_at']),
          timeline: [],
          routePoints: [point(request['pickup_point']), point(request['destination_point'])].filter(
            (p): p is GeoPoint => p !== undefined,
          ),
        };
        if (detail) await this.addDetail(view);
        return view;
      }),
    );
  }

  private async addDetail(view: JobAdminView): Promise<void> {
    const events = await this.gw.selectList('job_events', 'to_status, actor_kind, reason_code, created_at', {
      column: 'request_id',
      value: view.id,
      orderBy: 'created_at',
    });
    view.timeline = [
      { status: 'created', at: view.createdAt, actor: 'customer' },
      ...events.map((e) => ({
        status: e['to_status'] as JobStatus,
        at: SupabaseGateway.asTimestamp(e['created_at']),
        actor: actorOf(e['actor_kind']),
        note: e['reason_code'] ? String(e['reason_code']) : undefined,
      })),
    ];
    // The trail is the most sensitive thing in the schema: a super admin reads it, audited,
    // and anybody else simply gets the two ends of the route.
    try {
      const trail = await this.gw.rpcRows('job_trail', { p_request_id: view.id });
      const points = trail.map((t) => ({ latitude: Number(t['lat']), longitude: Number(t['lng']) }));
      if (points.length > 0) {
        view.routePoints = points;
        if (view.status === 'en_route' || view.status === 'arrived' || view.status === 'in_progress') {
          view.livePosition = points[points.length - 1];
        }
      }
    } catch {
      // Not a super admin, or no trail yet.
    }
  }
}
