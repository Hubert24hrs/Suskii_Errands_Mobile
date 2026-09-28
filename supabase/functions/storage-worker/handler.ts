// The outbox's third reader. It claims the `storage` aggregate and does one thing: removes a
// user's folder from a bucket through the Storage API, because Storage refuses direct deletes
// from storage.objects (storage.protect_delete) and erasure runs in SQL (audit 2026-09-27 Y.30).
//
// Deleting is the one thing a worker must never do too much of, so the event is checked before
// anything is listed: the bucket must be on the allowlist and the prefix must be exactly one
// user's folder. An empty or malformed prefix would otherwise name the whole bucket.

export type ClaimedEvent = {
  id: number;
  aggregate: string;
  aggregate_id: string;
  event_type: string;
  payload: Record<string, unknown>;
  attempts: number;
};

export type StoredEntry = { name: string; isFolder: boolean };

export type WorkerDeps = {
  claim(aggregates: string[], limit: number): Promise<ClaimedEvent[]>;
  complete(id: number): Promise<void>;
  fail(id: number, reasonKey: string, retry: boolean): Promise<void>;
  /** One page of a folder's entries (names relative to the folder). */
  list(bucket: string, folder: string, limit: number, offset: number): Promise<StoredEntry[]>;
  remove(bucket: string, paths: string[]): Promise<void>;
  log(level: "info" | "warn" | "error", message: string, fields?: Record<string, unknown>): void;
};

export type WorkerResult = { claimed: number; completed: number; failed: number; removed: number };

/** Buckets erasure may empty a folder of. kyc-docs is kept for its legal retention period. */
export const ERASABLE_BUCKETS: ReadonlySet<string> = new Set(["avatars"]);

const USER_FOLDER = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\/$/;
const PAGE = 1000;

/** The event's bucket and prefix when both are safe to act on, else null. */
export function erasureTarget(
  event: ClaimedEvent,
): { bucket: string; prefix: string } | null {
  const bucket = event.payload?.["bucket"];
  const prefix = event.payload?.["prefix"];
  if (typeof bucket !== "string" || !ERASABLE_BUCKETS.has(bucket)) return null;
  if (typeof prefix !== "string" || !USER_FOLDER.test(prefix)) return null;
  // The folder must be the user the event is about, not merely any user.
  if (prefix !== `${event.aggregate_id}/`) return null;
  return { bucket, prefix };
}

async function collect(deps: WorkerDeps, bucket: string, folder: string): Promise<string[]> {
  const paths: string[] = [];
  for (let offset = 0;; offset += PAGE) {
    const page = await deps.list(bucket, folder, PAGE, offset);
    for (const entry of page) {
      const path = `${folder}/${entry.name}`;
      if (entry.isFolder) paths.push(...await collect(deps, bucket, path));
      else paths.push(path);
    }
    if (page.length < PAGE) return paths;
  }
}

export function createStorageWorker(deps: WorkerDeps) {
  return async function run(limit = 20): Promise<WorkerResult> {
    const events = await deps.claim(["storage"], limit);
    let completed = 0, failed = 0, removed = 0;

    for (const event of events) {
      if (event.event_type !== "storage.erase_prefix") {
        // Only erasure writes this aggregate, so anything else is a bug upstream: kept visible
        // as a failure rather than completed unread.
        deps.log("error", "storage.worker.unknown_event", {
          event_id: event.id,
          event_type: event.event_type,
        });
        await deps.fail(event.id, "ERR_UNKNOWN_EVENT", false);
        failed++;
        continue;
      }
      const target = erasureTarget(event);
      if (!target) {
        deps.log("error", "storage.worker.refused_target", { event_id: event.id });
        await deps.fail(event.id, "ERR_INVALID_PAYLOAD", false);
        failed++;
        continue;
      }
      try {
        const paths = await collect(deps, target.bucket, target.prefix.slice(0, -1));
        for (let i = 0; i < paths.length; i += PAGE) {
          await deps.remove(target.bucket, paths.slice(i, i + PAGE));
        }
        removed += paths.length;
        await deps.complete(event.id);
        completed++;
        deps.log("info", "storage.worker.erased", {
          event_id: event.id,
          bucket: target.bucket,
          objects: paths.length,
        });
      } catch (error) {
        deps.log("warn", "storage.worker.retry", {
          event_id: event.id,
          error: error instanceof Error ? error.message : String(error),
        });
        await deps.fail(event.id, "ERR_STORAGE_UNAVAILABLE", true);
        failed++;
      }
    }
    return { claimed: events.length, completed, failed, removed };
  };
}
