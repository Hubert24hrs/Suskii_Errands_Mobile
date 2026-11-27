import { assert, assertEquals } from "@std/assert";
import images from "../_shared/media/testdata/images.json" with { type: "json" };
import { metadataBlocks } from "../_shared/media/strip_metadata.ts";
import {
  type ClaimedEvent,
  createMeetMediaWorker,
  type Ingested,
  ingestTarget,
  type MediaWorkerDeps,
} from "./handler.ts";

const UID = "11111111-1111-4111-8111-111111111111";
const PROFILE = "22222222-2222-4222-8222-222222222222";
const PHOTO = "33333333-3333-4333-8333-333333333333";
const MAIN = `${UID}/44444444-4444-4444-8444-444444444444.jpg`;
const THUMB = `${UID}/55555555-5555-4555-8555-555555555555.jpg`;

function bytes(name: keyof typeof images): Uint8Array {
  return Uint8Array.from(atob(images[name]), (c) => c.charCodeAt(0));
}

/** A JPEG fixture with its SOF height and width rewritten, so a size check can be exercised. */
function jpegSized(width: number, height: number): Uint8Array {
  const b = bytes("gps_exif.jpg").slice();
  const sof = b.findIndex((v, i) => v === 0xff && b[i + 1] === 0xc0);
  b[sof + 5] = height >> 8;
  b[sof + 6] = height & 0xff;
  b[sof + 7] = width >> 8;
  b[sof + 8] = width & 0xff;
  return b;
}

function ingest(payload: Record<string, unknown> = {}, extra: Partial<ClaimedEvent> = {}): ClaimedEvent {
  return {
    id: 9,
    aggregate: "meet_media",
    aggregate_id: PROFILE,
    event_type: "meet.media.ingest",
    payload: { kind: "photo", id: PHOTO, profile_id: PROFILE, inbox_path: MAIN, thumb_inbox_path: THUMB, ...payload },
    attempts: 1,
    ...extra,
  };
}

function harness(
  events: ClaimedEvent[],
  objects: Record<string, Uint8Array>,
  overrides: Partial<MediaWorkerDeps> = {},
) {
  const store = new Map(Object.entries(objects));
  const calls: string[] = [];
  const reports: Ingested[] = [];
  const deps: MediaWorkerDeps = {
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
    download: (bucket, path) => Promise.resolve(store.get(`${bucket}/${path}`) ?? null),
    upload: (bucket, path, data, contentType) => {
      calls.push(`upload:${bucket}/${path}:${contentType}`);
      store.set(`${bucket}/${path}`, data);
      return Promise.resolve();
    },
    remove: (bucket, paths) => {
      for (const p of paths) store.delete(`${bucket}/${p}`);
      calls.push(`remove:${bucket}:${paths.length}`);
      return Promise.resolve();
    },
    ingested: (item) => {
      reports.push(item);
      calls.push(`ingested:${item.id}`);
      return Promise.resolve(true);
    },
    failed: (kind, id, reason) => {
      calls.push(`failed:${kind}:${id}:${reason}`);
      return Promise.resolve();
    },
    log: () => {},
    ...overrides,
  };
  return { deps, store, calls, reports };
}

const thumbnail = () => jpegSized(320, 256);
const inbox = (main = bytes("gps_exif.jpg"), thumb = thumbnail()) => ({
  [`meet-inbox/${MAIN}`]: main,
  [`meet-inbox/${THUMB}`]: thumb,
});

Deno.test("claims only the meet_media aggregate", async () => {
  const h = harness([], {});
  await createMeetMediaWorker(h.deps)();
  assertEquals(h.calls, ["claim:meet_media"]);
});

Deno.test("a photo is stripped, written under the profile id, reported, and only then removed from the inbox", async () => {
  const h = harness([ingest()], inbox());
  const result = await createMeetMediaWorker(h.deps)();
  assertEquals(result, { claimed: 1, ingested: 1, rejected: 0, discarded: 0, failed: 0 });
  assertEquals(h.calls, [
    "claim:meet_media",
    `upload:meet-media/${PROFILE}/p/${PHOTO}.jpg:image/jpeg`,
    `upload:meet-media/${PROFILE}/pt/${PHOTO}.jpg:image/jpeg`,
    `ingested:${PHOTO}`,
    "remove:meet-inbox:2",
    "complete:9",
  ]);
  const written = h.store.get(`meet-media/${PROFILE}/p/${PHOTO}.jpg`)!;
  assertEquals(metadataBlocks(written), [], "nothing a phone wrote survives");
  assertEquals(metadataBlocks(h.store.get(`meet-media/${PROFILE}/pt/${PHOTO}.jpg`)!), []);
  assertEquals([...h.store.keys()].filter((k) => k.startsWith("meet-inbox/")), [], "the inbox is empty");
  const [report] = h.reports;
  assertEquals([report.width, report.height, report.mime], [400, 320, "image/jpeg"]);
  assert(/^[0-9a-f]{64}$/.test(report.sha256));
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new Uint8Array(written)));
  assertEquals(report.sha256, [...digest].map((b) => b.toString(16).padStart(2, "0")).join(""));
});

Deno.test("no path the worker writes contains the uploader's auth uid", async () => {
  const h = harness([ingest()], inbox());
  await createMeetMediaWorker(h.deps)();
  const written = h.calls.filter((c) => c.startsWith("upload:")).join(" ");
  assert(!written.includes(UID));
  assert(!JSON.stringify(h.reports).includes(UID));
});

Deno.test("the extension follows the bytes, not the name the client chose", async () => {
  const h = harness([ingest()], inbox(bytes("xmp_exif.webp")));
  await createMeetMediaWorker(h.deps)();
  assert(h.calls.includes(`upload:meet-media/${PROFILE}/p/${PHOTO}.webp:image/webp`));
  assertEquals(h.reports[0].mime, "image/webp");
});

Deno.test("an unusable photo is reported as failed with its reason, its inbox copies removed, never retried", async () => {
  const cases: [Record<string, Uint8Array>, string][] = [
    [{ [`meet-inbox/${THUMB}`]: thumbnail() }, "not_found"],
    [inbox(new TextEncoder().encode("<svg/>")), "bad_type"],
    [inbox(bytes("gps_exif.jpg").subarray(0, 900)), "corrupt"],
    [inbox(jpegSized(200, 200)), "bad_dimensions"],
    [inbox(jpegSized(5000, 3000)), "bad_dimensions"],
    [inbox(bytes("gps_exif.jpg"), jpegSized(1080, 1350)), "bad_dimensions"],
  ];
  for (const [objects, reason] of cases) {
    const h = harness([ingest()], objects);
    const result = await createMeetMediaWorker(h.deps)();
    assertEquals(result.rejected, 1, reason);
    assertEquals(h.calls.slice(1), [`failed:photo:${PHOTO}:${reason}`, "remove:meet-inbox:2", "complete:9"], reason);
    assertEquals([...h.store.keys()].filter((k) => k.startsWith("meet-media/")), [], reason);
  }
});

Deno.test("a photo removed while it waited has its new files deleted again", async () => {
  const h = harness([ingest()], inbox(), { ingested: () => Promise.resolve(false) });
  const result = await createMeetMediaWorker(h.deps)();
  assertEquals(result.discarded, 1);
  assertEquals([...h.store.keys()], [], "neither meet-media nor the inbox keeps anything");
  assertEquals(h.calls.at(-1), "complete:9");
});

Deno.test("storage or database trouble is retried, and the inbox is kept until the report lands", async () => {
  const outages: Partial<MediaWorkerDeps>[] = [
    { download: () => Promise.reject(new Error("503")) },
    { upload: () => Promise.reject(new Error("503")) },
    { ingested: () => Promise.reject(new Error("connection reset")) },
  ];
  for (const outage of outages) {
    const h = harness([ingest()], inbox(), outage);
    await createMeetMediaWorker(h.deps)();
    assertEquals(h.calls.at(-1), "fail:9:ERR_STORAGE_UNAVAILABLE:true");
    assert(h.store.has(`meet-inbox/${MAIN}`), "the original is still there for the retry");
  }
});

Deno.test("a malformed event fails without retry and touches nothing", async () => {
  const bad: ClaimedEvent[] = [
    ingest({ kind: "status" }),
    ingest({ id: "not-a-uuid" }),
    ingest({ profile_id: "66666666-6666-4666-8666-666666666666" }), // not the aggregate
    ingest({ inbox_path: `../${MAIN}` }),
    ingest({ inbox_path: `${UID}/sub/44444444-4444-4444-8444-444444444444.jpg` }),
    ingest({ inbox_path: `${UID}/44444444-4444-4444-8444-444444444444.gif` }),
    ingest({ thumb_inbox_path: `66666666-6666-4666-8666-666666666666/55555555-5555-4555-8555-555555555555.jpg` }),
    ingest({ thumb_inbox_path: MAIN }),
  ];
  for (const event of bad) {
    assertEquals(ingestTarget(event), null, JSON.stringify(event.payload));
    const h = harness([event], inbox());
    await createMeetMediaWorker(h.deps)();
    assertEquals(h.calls.slice(1), ["fail:9:ERR_INVALID_PAYLOAD:false"]);
    assertEquals(h.store.size, 2);
  }
  const unknown = harness([ingest({}, { event_type: "meet.media.other" })], inbox());
  await createMeetMediaWorker(unknown.deps)();
  assertEquals(unknown.calls.at(-1), "fail:9:ERR_UNKNOWN_EVENT:false");
});
