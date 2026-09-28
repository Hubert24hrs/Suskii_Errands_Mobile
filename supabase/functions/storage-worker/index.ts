import "@supabase/functions-js/edge-runtime.d.ts";
import { withSupabase } from "@supabase/server";
import { createAdminClient } from "@supabase/server/core";
import { log } from "../_shared/log.ts";
import { instrument } from "../_shared/observability.ts";
import { sentryReporterFromEnv } from "../_shared/sentry.ts";
import { type ClaimedEvent, createStorageWorker } from "./handler.ts";

// Invoked on a schedule, like the other workers. Drains `private.outbox` for the `storage`
// aggregate: the folders account erasure could not delete from SQL (audit 2026-09-27 Y.30).
const admin = createAdminClient();

const run = createStorageWorker({
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
  async list(bucket, folder, limit, offset) {
    const { data, error } = await admin.storage.from(bucket).list(folder, { limit, offset });
    if (error) throw new Error(error.message);
    // The Storage API reports a folder as an entry without an id.
    return (data ?? []).map((entry) => ({ name: entry.name, isFolder: entry.id === null }));
  },
  async remove(bucket, paths) {
    const { error } = await admin.storage.from(bucket).remove(paths);
    if (error) throw new Error(error.message);
  },
  log,
});

export default {
  fetch: instrument(
    "storage-worker",
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
