// Health endpoint for uptime checks (infra-cicd.md §7). Proves the function runtime, the
// database connection and the database's own checks in one call. Returns 503 when any check
// fails so a plain HTTP uptime check alerts without parsing the body; warnings stay 200 and are
// visible in the body and dashboards.

import { json } from "../_shared/http.ts";

export interface HealthSnapshot {
  status: "ok" | "warn" | "fail";
  checked_at: string;
  checks: Record<string, { status: string; [key: string]: unknown }>;
}

export interface HealthDeps {
  getHealth(): Promise<HealthSnapshot>;
  release?: string;
  now?: () => number;
}

export function createHealthHandler(deps: HealthDeps) {
  const now = deps.now ?? (() => performance.now());

  return async (req: Request): Promise<Response> => {
    if (req.method !== "GET") return json({ error: { code: "ERR_METHOD_NOT_ALLOWED" } }, 405);

    const started = now();
    let snapshot: HealthSnapshot;
    try {
      snapshot = await deps.getHealth();
    } catch {
      return json({ status: "fail", checks: { database: { status: "fail", reason: "unreachable" } } }, 503, {
        "cache-control": "no-store",
      });
    }
    const dbLatencyMs = Math.round(now() - started);

    return json(
      { ...snapshot, db_latency_ms: dbLatencyMs, release: deps.release ?? null },
      snapshot.status === "fail" ? 503 : 200,
      { "cache-control": "no-store" },
    );
  };
}
