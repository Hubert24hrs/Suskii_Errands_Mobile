import { assertEquals } from "@std/assert";
import { type ClaimedEvent, createStorageWorker, erasureTarget, type StoredEntry, type WorkerDeps } from "./handler.ts";

const USER = "11111111-1111-4111-8111-111111111111";

function erase(payload: Record<string, unknown>, extra: Partial<ClaimedEvent> = {}): ClaimedEvent {
  return {
    id: 7,
    aggregate: "storage",
    aggregate_id: USER,
    event_type: "storage.erase_prefix",
    payload,
    attempts: 1,
    ...extra,
  };
}

/** An in-memory bucket keyed by full path. */
function fakeStorage(files: string[]) {
  const store = new Set(files);
  const removed: string[] = [];
  const list = (_bucket: string, folder: string, limit: number, offset: number): Promise<StoredEntry[]> => {
    const prefix = `${folder}/`;
    const children = new Map<string, boolean>();
    for (const path of store) {
      if (!path.startsWith(prefix)) continue;
      const rest = path.slice(prefix.length);
      const [head, ...tail] = rest.split("/");
      children.set(head, tail.length > 0 || children.get(head) === true);
    }
    const entries = [...children.entries()].sort().map(([name, isFolder]) => ({ name, isFolder }));
    return Promise.resolve(entries.slice(offset, offset + limit));
  };
  const remove = (_bucket: string, paths: string[]) => {
    for (const p of paths) {
      store.delete(p);
      removed.push(p);
    }
    return Promise.resolve();
  };
  return { store, removed, list, remove };
}

function deps(events: ClaimedEvent[], storage = fakeStorage([]), overrides: Partial<WorkerDeps> = {}) {
  const calls: string[] = [];
  const base: WorkerDeps = {
    claim: (aggregates) => {
      calls.push(`claim:${aggregates.join(",")}`);
      return Promise.resolve(events);
    },
    complete: (id) => {
      calls.push(`complete:${id}`);
      return Promise.resolve();
    },
    fail: (id, reason, retry) => {
      calls.push(`fail:${id}:${reason}:${retry}`);
      return Promise.resolve();
    },
    list: storage.list,
    remove: storage.remove,
    log: () => {},
    ...overrides,
  };
  return { deps: base, calls };
}

Deno.test("claims only the storage aggregate", async () => {
  const { deps: d, calls } = deps([]);
  await createStorageWorker(d)();
  assertEquals(calls, ["claim:storage"]);
});

Deno.test("removes every object in the user's folder, nested ones included, and nothing else", async () => {
  const storage = fakeStorage([
    `${USER}/avatar.jpg`,
    `${USER}/old/avatar-2025.jpg`,
    "22222222-2222-4222-8222-222222222222/avatar.jpg",
  ]);
  const { deps: d, calls } = deps([erase({ bucket: "avatars", prefix: `${USER}/` })], storage);
  const result = await createStorageWorker(d)();
  assertEquals(storage.removed.sort(), [`${USER}/avatar.jpg`, `${USER}/old/avatar-2025.jpg`]);
  assertEquals([...storage.store], ["22222222-2222-4222-8222-222222222222/avatar.jpg"]);
  assertEquals(calls.at(-1), "complete:7");
  assertEquals(result, { claimed: 1, completed: 1, failed: 0, removed: 2 });
});

Deno.test("an empty folder is still a completed erasure", async () => {
  const { deps: d, calls } = deps([erase({ bucket: "avatars", prefix: `${USER}/` })]);
  const result = await createStorageWorker(d)();
  assertEquals(calls.at(-1), "complete:7");
  assertEquals(result.removed, 0);
});

Deno.test("pages through a folder larger than one listing", async () => {
  const files = Array.from({ length: 2500 }, (_, i) => `${USER}/f${String(i).padStart(4, "0")}.jpg`);
  const storage = fakeStorage(files);
  const { deps: d } = deps([erase({ bucket: "avatars", prefix: `${USER}/` })], storage);
  const result = await createStorageWorker(d)();
  assertEquals(result.removed, 2500);
  assertEquals(storage.store.size, 0);
});

Deno.test("never acts on a prefix that is not exactly the event's own user folder", () => {
  const bad = [
    "", // the whole bucket
    "/",
    USER, // no trailing slash: would also match a sibling named USER + "x"
    `${USER}/sub/`,
    "22222222-2222-4222-8222-222222222222/", // somebody else
    "../",
  ];
  for (const prefix of bad) {
    assertEquals(erasureTarget(erase({ bucket: "avatars", prefix })), null, `prefix ${JSON.stringify(prefix)}`);
  }
  assertEquals(erasureTarget(erase({ bucket: "avatars", prefix: `${USER}/` })), {
    bucket: "avatars",
    prefix: `${USER}/`,
  });
});

Deno.test("refuses a bucket outside the allowlist, identity documents above all", async () => {
  const storage = fakeStorage([`${USER}/passport.jpg`]);
  const { deps: d, calls } = deps([erase({ bucket: "kyc-docs", prefix: `${USER}/` })], storage);
  await createStorageWorker(d)();
  assertEquals(storage.removed, []);
  assertEquals(calls.at(-1), "fail:7:ERR_INVALID_PAYLOAD:false");
});

Deno.test("an unknown event type fails without retry instead of being completed unread", async () => {
  const { deps: d, calls } = deps([erase({}, { event_type: "storage.something_else" })]);
  await createStorageWorker(d)();
  assertEquals(calls.at(-1), "fail:7:ERR_UNKNOWN_EVENT:false");
});

Deno.test("a Storage outage is retried", async () => {
  const storage = fakeStorage([`${USER}/avatar.jpg`]);
  const { deps: d, calls } = deps([erase({ bucket: "avatars", prefix: `${USER}/` })], storage, {
    remove: () => Promise.reject(new Error("503")),
  });
  await createStorageWorker(d)();
  assertEquals(calls.at(-1), "fail:7:ERR_STORAGE_UNAVAILABLE:true");
});
