// Jobs repository: search across requests/offers/jobs with the full state
// timeline and approximate route points for the live map. Read-only — the
// console observes jobs, it does not move them through the state machine.

import { AppError, ErrorCodes } from '../errors';
import type { JobAdminView, JobStatus } from '../types';
import { MockRepo, type Unsubscribe } from './base';

export interface JobSearchFilter {
  text?: string;
  status?: JobStatus;
  country?: string;
  customerId?: string;
  providerId?: string;
}

export class MockJobsRepository extends MockRepo {
  async searchJobs(filter?: JobSearchFilter): Promise<JobAdminView[]> {
    await this.gate();
    this.requirePermission('jobs.read');
    return Object.values(this.db.jobs).filter((job) => {
      if (filter?.status && job.status !== filter.status) return false;
      if (filter?.country && job.country !== filter.country) return false;
      if (filter?.customerId && job.customerId !== filter.customerId) return false;
      if (filter?.providerId && job.providerId !== filter.providerId) return false;
      if (filter?.text) {
        const q = filter.text.toLowerCase();
        const haystack = `${job.id} ${job.title} ${job.customerName} ${job.providerName ?? ''}`.toLowerCase();
        if (!haystack.includes(q)) return false;
      }
      return true;
    });
  }

  /** Full detail: timeline events + route points + live position. */
  async getJob(jobId: string): Promise<JobAdminView> {
    await this.gate();
    this.requirePermission('jobs.read');
    const job = this.db.jobs[jobId];
    if (!job) throw new AppError(ErrorCodes.unknown);
    return job;
  }

  /**
   * Live-map subscription: emits the job whenever an in-progress job's
   * position updates (driven by the SOS ticker in this mock layer).
   */
  watchJob(jobId: string, listener: (job: JobAdminView) => void): Unsubscribe {
    this.requirePermission('jobs.read');
    const job = this.db.jobs[jobId];
    if (!job) throw new AppError(ErrorCodes.unknown);
    listener(job);
    return this.db.sosEvents.subscribe(() => {
      const current = this.db.jobs[jobId];
      if (current) listener(current);
    });
  }
}
