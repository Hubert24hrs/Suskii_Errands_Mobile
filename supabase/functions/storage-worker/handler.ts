// The outbox's third reader. It claims the `storage` aggregate and removes objects through the
// Storage API, because Storage refuses direct deletes from storage.objects (storage.protect_delete)
// and erasure runs in SQL (audit 2026-09-27 Y.30). Two events:
//
//   storage.erase_prefix  {bucket, prefix}  one owner's whole folder (account erasure, a deleted
//                                           Meet profile)
//   storage.erase_object  {bucket, path}    one object (a Meet photo or status taken down or
//                                           removed, a verification selfie past its retention)
//
// Deleting is the one thing a worker must never do too much of, so each event is checked before
// anything is listed or removed: the bucket must be on the allowlist, the prefix or path must sit
// in the event's own folder (the aggregate id), and an object path must have exactly the shape its
// bucket stores. An empty or malformed prefix would otherwise name the whole bucket, and a path
// with `..` or a stray segment would name something else.

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

/**
 * Buckets erasure may delete from. kyc-docs is kept for its legal retention period and is never
 * here. The Meet buckets (Meet v5 design §2.7): `meet-inbox` and `meet-verify` are foldered by the
 * uploader's auth uid, `meet-media` by the opaque Meet profile id.
 */
export const ERASABLE_BUCKETS: ReadonlySet<string> = new Set(["avatars", "meet-inbox", "meet-media", "meet-verify"]);

const UUID = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
const USER_FOLDER = new RegExp(`^${UUID}/$`);

/**
 * The only object paths `storage.erase_object` may name, per bucket. A bucket without an entry
 * (avatars) is erased by folder only. Folder and file names are lower-case uuids, so no pattern
 * admits `..`, an empty segment or a nested folder.
 */
export const ERASABLE_OBJECTS: Readonly<Record<string, RegExp>> = {
  "meet-media": new RegExp(`^${UUID}/(p|pt|s)/${UUID}\\.(jpg|png|webp)$`),
  "meet-inbox": new RegExp(`^${UUID}/${UUID}\\.(jpg|png|webp)$`),
  "meet-verify": new RegExp(`^${UUID}/${UUID}\\.jpg$`),
};

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

/** The event's bucket and object path when both are safe to act on, else null. */
export function objectTarget(
  event: ClaimedEvent,
): { bucket: string; path: string } | null {
  const bucket = event.payload?.["bucket"];
  const path = event.payload?.["path"];
  if (typeof bucket !== "string" || !ERASABLE_BUCKETS.has(bucket)) return null;
  const shape = ERASABLE_OBJECTS[bucket];
  if (!shape || typeof path !== "string" || !shape.test(path)) return null;
  // The object must sit in the folder the event is about, not merely in any folder.
  if (!path.startsWith(`${event.aggregate_id}/`)) return null;
  return { bucket, path };
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
      if (event.event_type === "storage.erase_object") {
        const object = objectTarget(event);
        if (!object) {
          deps.log("error", "storage.worker.refused_target", { event_id: event.id });
          await deps.fail(event.id, "ERR_INVALID_PAYLOAD", false);
          failed++;
          continue;
        }
        try {
          // Removing an object that is already gone succeeds, so a retry is harmless.
          await deps.remove(object.bucket, [object.path]);
          removed += 1;
          await deps.complete(event.id);
          completed++;
          deps.log("info", "storage.worker.erased", { event_id: event.id, bucket: object.bucket, objects: 1 });
        } catch (error) {
          deps.log("warn", "storage.worker.retry", {
            event_id: event.id,
            error: error instanceof Error ? error.message : String(error),
          });
          await deps.fail(event.id, "ERR_STORAGE_UNAVAILABLE", true);
          failed++;
        }
        continue;
      }
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
