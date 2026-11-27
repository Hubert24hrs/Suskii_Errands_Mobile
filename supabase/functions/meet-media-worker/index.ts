import "@supabase/functions-js/edge-runtime.d.ts";
import { withSupabase } from "@supabase/server";
import { createAdminClient } from "@supabase/server/core";
import { log } from "../_shared/log.ts";
import { instrument } from "../_shared/observability.ts";
import { sentryReporterFromEnv } from "../_shared/sentry.ts";
import { type ClaimedEvent, createMeetMediaWorker } from "./handler.ts";

// Invoked every minute by `meet-media-dispatch` through `private.invoke_edge_worker`, with the
// same named secret API key as the other workers. Drains `private.outbox` for the `meet_media`
// aggregate: photos `meet_submit_photo` queued (Meet v5 design §2.7).
const admin = createAdminClient();

function isNotFound(error: { message?: string; status?: number; statusCode?: string } | null): boolean {
  if (!error) return false;
  return error.status === 404 || error.statusCode === "404" || /not.?found/i.test(error.message ?? "");
}

const run = createMeetMediaWorker({
  async claim(aggregates, limit) {
    const { data, error } = await admin.rpc("gateway_claim_outbox", {
      p_aggregates: aggregates,
      p_limit: limit,
    });
    if (error) throw new Error(error.message);
    return (data ?? []) as ClaimedEvent[];
  },
  async complete(id) {
    const { error } = await admin.rpc("gateway_complete_outbox", { p_id: id });
    if (error) throw new Error(error.message);
  },
  async fail(id, reasonKey, retry) {
    const { error } = await admin.rpc("gateway_fail_outbox", {
      p_id: id,
      p_reason_key: reasonKey,
      p_retry: retry,
    });
    if (error) throw new Error(error.message);
  },
  async download(bucket, path) {
    const { data, error } = await admin.storage.from(bucket).download(path);
    if (isNotFound(error as { message?: string; status?: number; statusCode?: string } | null)) return null;
    if (error) throw new Error(error.message);
    return new Uint8Array(await data.arrayBuffer());
  },
  async upload(bucket, path, bytes, contentType) {
    const { error } = await admin.storage.from(bucket).upload(path, bytes, { contentType, upsert: true });
    if (error) throw new Error(error.message);
  },
  async remove(bucket, paths) {
    const { error } = await admin.storage.from(bucket).remove(paths);
    if (error) throw new Error(error.message);
  },
  async ingested(item) {
    const { data, error } = await admin.rpc("gateway_meet_media_ingested", {
      p_kind: item.kind,
      p_id: item.id,
      p_media_path: item.mediaPath,
      p_thumb_path: item.thumbPath,
      p_sha256: item.sha256,
      p_width: item.width,
      p_height: item.height,
      p_mime: item.mime,
    });
    if (error) throw new Error(error.message);
    return (data as { accepted?: boolean } | null)?.accepted === true;
  },
  async failed(kind, id, reason) {
    const { error } = await admin.rpc("gateway_meet_media_failed", { p_kind: kind, p_id: id, p_reason: reason });
    if (error) throw new Error(error.message);
  },
  log,
});

export default {
  fetch: instrument(
    "meet-media-worker",
    withSupabase({ auth: "secret:worker", cors: "disabled" }, async () => {
      const result = await run();
      return new Response(JSON.stringify(result), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    }),
    { reporter: sentryReporterFromEnv() },
  ),
};
