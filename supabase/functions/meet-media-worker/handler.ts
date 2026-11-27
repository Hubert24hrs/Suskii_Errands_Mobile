// The Meet media pipeline's worker (Meet v5 design §2.4, §2.7, §8.5). It claims the `meet_media`
// outbox aggregate, which `meet_submit_photo` writes once per photo, and for each one:
//
//   1. downloads the photo and its thumbnail from `meet-inbox/<uid>/`, where only the uploader
//      could write and nobody but this worker can read;
//   2. checks the magic bytes and dimensions and strips metadata byte by byte (no re-encode);
//   3. writes both to `meet-media/<profile_id>/p|pt/<photo_id>.<ext>`, a path with no auth uid in
//      it, because these are the files other people's apps fetch (D15);
//   4. reports through `gateway_meet_media_ingested`, which puts the photo in front of a person
//      (OD-41: nobody else sees it before that), and only then deletes the inbox copies.
//
// A photo the worker cannot use is reported through `gateway_meet_media_failed` with a reason the
// app can turn into "try another photo"; that is an answer, not a retry. Storage or database
// trouble is retried. The report is idempotent in the database, so a retry after a partial run
// (files written, inbox not yet emptied) does no harm.

import { MediaError, type MediaFailure, metadataBlocks, stripMetadata } from "../_shared/media/strip_metadata.ts";

export type ClaimedEvent = {
  id: number;
  aggregate: string;
  aggregate_id: string;
  event_type: string;
  payload: Record<string, unknown>;
  attempts: number;
};

export type Ingested = {
  kind: "photo";
  id: string;
  mediaPath: string;
  thumbPath: string;
  sha256: string;
  width: number;
  height: number;
  mime: string;
};

export type FailureReason = MediaFailure | "not_found" | "too_large" | "bad_dimensions";

export type MediaWorkerDeps = {
  claim(aggregates: string[], limit: number): Promise<ClaimedEvent[]>;
  complete(id: number): Promise<void>;
  fail(id: number, reasonKey: string, retry: boolean): Promise<void>;
  /** The object's bytes, or null when it does not exist. Any other failure throws. */
  download(bucket: string, path: string): Promise<Uint8Array | null>;
  upload(bucket: string, path: string, bytes: Uint8Array, contentType: string): Promise<void>;
  remove(bucket: string, paths: string[]): Promise<void>;
  /** False when the photo is no longer waiting for its files (removed, or the profile deleted). */
  ingested(item: Ingested): Promise<boolean>;
  failed(kind: string, id: string, reason: FailureReason): Promise<void>;
  log(level: "info" | "warn" | "error", message: string, fields?: Record<string, unknown>): void;
};

export type MediaWorkerResult = {
  claimed: number;
  ingested: number;
  rejected: number;
  discarded: number;
  failed: number;
};

export const INBOX = "meet-inbox";
export const MEDIA = "meet-media";

/** meet-media's own limit; the inbox takes up to 8 MB, and stripping only ever shrinks a file. */
export const MAX_BYTES = 5 * 1024 * 1024;
/** Each side, in pixels. The app sends 1080 px and a 320 px thumbnail (§2.7). */
export const MAIN_SIDE = { min: 320, max: 4096 };
export const THUMB_SIDE = { min: 160, max: 480 };

const UUID = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
const INBOX_PATH = new RegExp(`^(${UUID})/${UUID}\\.(jpg|png|webp)$`);
const ID = new RegExp(`^${UUID}$`);

type Target = { id: string; profileId: string; inboxPath: string; thumbInboxPath: string };

/** The event's photo when every part of it is well formed, else null. */
export function ingestTarget(event: ClaimedEvent): Target | null {
  const p = event.payload ?? {};
  const { kind, id, profile_id: profileId, inbox_path: inboxPath, thumb_inbox_path: thumbInboxPath } = p;
  if (kind !== "photo") return null;
  if (typeof id !== "string" || !ID.test(id)) return null;
  if (typeof profileId !== "string" || profileId !== event.aggregate_id || !ID.test(profileId)) return null;
  if (typeof inboxPath !== "string" || typeof thumbInboxPath !== "string") return null;
  const main = INBOX_PATH.exec(inboxPath);
  const thumb = INBOX_PATH.exec(thumbInboxPath);
  // Both from one uploader's folder, and two different objects.
  if (!main || !thumb || main[1] !== thumb[1] || inboxPath === thumbInboxPath) return null;
  return { id, profileId, inboxPath, thumbInboxPath };
}

function withinSides(width: number, height: number, side: { min: number; max: number }): boolean {
  return [width, height].every((v) => v >= side.min && v <= side.max);
}

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new Uint8Array(bytes)));
  return [...digest].map((b) => b.toString(16).padStart(2, "0")).join("");
}

class Unusable extends Error {
  constructor(readonly reason: FailureReason) {
    super(reason);
  }
}

function prepare(bytes: Uint8Array, side: { min: number; max: number }) {
  let out;
  try {
    out = stripMetadata(bytes);
  } catch (error) {
    if (error instanceof MediaError) throw new Unusable(error.reason);
    throw error;
  }
  if (metadataBlocks(out.bytes).length > 0) throw new Unusable("corrupt");
  if (out.bytes.length > MAX_BYTES) throw new Unusable("too_large");
  if (!withinSides(out.width, out.height, side)) throw new Unusable("bad_dimensions");
  return out;
}

export function createMeetMediaWorker(deps: MediaWorkerDeps) {
  return async function run(limit = 10): Promise<MediaWorkerResult> {
    const events = await deps.claim(["meet_media"], limit);
    const result: MediaWorkerResult = { claimed: events.length, ingested: 0, rejected: 0, discarded: 0, failed: 0 };

    for (const event of events) {
      if (event.event_type !== "meet.media.ingest") {
        deps.log("error", "meet_media.worker.unknown_event", { event_id: event.id, event_type: event.event_type });
        await deps.fail(event.id, "ERR_UNKNOWN_EVENT", false);
        result.failed++;
        continue;
      }
      const target = ingestTarget(event);
      if (!target) {
        deps.log("error", "meet_media.worker.refused_payload", { event_id: event.id });
        await deps.fail(event.id, "ERR_INVALID_PAYLOAD", false);
        result.failed++;
        continue;
      }

      const written: string[] = [];
      try {
        const [main, thumb] = await Promise.all([
          deps.download(INBOX, target.inboxPath),
          deps.download(INBOX, target.thumbInboxPath),
        ]);
        let photo, small;
        try {
          if (!main || !thumb) throw new Unusable("not_found");
          photo = prepare(main, MAIN_SIDE);
          small = prepare(thumb, THUMB_SIDE);
        } catch (error) {
          if (!(error instanceof Unusable)) throw error;
          await deps.failed("photo", target.id, error.reason);
          await deps.remove(INBOX, [target.inboxPath, target.thumbInboxPath]);
          await deps.complete(event.id);
          result.rejected++;
          // The reason only: never the path, which names the uploader.
          deps.log("info", "meet_media.worker.rejected", { event_id: event.id, reason: error.reason });
          continue;
        }

        const mediaPath = `${target.profileId}/p/${target.id}.${photo.extension}`;
        const thumbPath = `${target.profileId}/pt/${target.id}.${small.extension}`;
        await deps.upload(MEDIA, mediaPath, photo.bytes, photo.mime);
        written.push(mediaPath);
        await deps.upload(MEDIA, thumbPath, small.bytes, small.mime);
        written.push(thumbPath);

        const accepted = await deps.ingested({
          kind: "photo",
          id: target.id,
          mediaPath,
          thumbPath,
          sha256: await sha256Hex(photo.bytes),
          width: photo.width,
          height: photo.height,
          mime: photo.mime,
        });
        if (!accepted) {
          // Removed while it waited, or the profile was deleted: nothing may keep its files.
          await deps.remove(MEDIA, written);
          result.discarded++;
        } else {
          result.ingested++;
        }
        await deps.remove(INBOX, [target.inboxPath, target.thumbInboxPath]);
        await deps.complete(event.id);
      } catch (error) {
        deps.log("warn", "meet_media.worker.retry", {
          event_id: event.id,
          error: error instanceof Error ? error.message : String(error),
        });
        await deps.fail(event.id, "ERR_STORAGE_UNAVAILABLE", true);
        result.failed++;
      }
    }
    return result;
  };
}
