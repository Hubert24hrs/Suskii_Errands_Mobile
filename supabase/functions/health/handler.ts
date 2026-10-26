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

// `?scope=safety` is RB-06's alarm: 503 while an escalated SOS is unacknowledged. It has its own uptime
// check and alert, so an SOS never fails the deploy smoke test, which reads the default scope.
export interface SafetyAlarm {
  status: "ok" | "fail";
  checked_at: string;
  unacknowledged: number;
  oldest_escalated_seconds: number | null;
}

export interface HealthDeps {
  getHealth(): Promise<HealthSnapshot>;
  getSafetyAlarm?(): Promise<SafetyAlarm>;
  release?: string;
  now?: () => number;
}

export function createHealthHandler(deps: HealthDeps) {
  const now = deps.now ?? (() => performance.now());

  return async (req: Request): Promise<Response> => {
    if (req.method !== "GET") return json({ error: { code: "ERR_METHOD_NOT_ALLOWED" } }, 405);
    const noStore = { "cache-control": "no-store" };

    const scope = new URL(req.url).searchParams.get("scope");
    if (scope === "safety" && deps.getSafetyAlarm) {
      try {
        const alarm = await deps.getSafetyAlarm();
        return json(alarm, alarm.status === "fail" ? 503 : 200, noStore);
      } catch {
        // Not knowing whether somebody is waiting pages too: for an SOS that is the safe direction.
        return json({ status: "fail", reason: "unreachable" }, 503, noStore);
      }
    }
    if (scope !== null) return json({ error: { code: "ERR_INVALID_ARGUMENT" } }, 400, noStore);

    const started = now();
    let snapshot: HealthSnapshot;
    try {
      snapshot = await deps.getHealth();
    } catch {
      return json({ status: "fail", checks: { database: { status: "fail", reason: "unreachable" } } }, 503, noStore);
    }
    const dbLatencyMs = Math.round(now() - started);

    return json(
      { ...snapshot, db_latency_ms: dbLatencyMs, release: deps.release ?? null },
      snapshot.status === "fail" ? 503 : 200,
      noStore,
    );
  };
}
