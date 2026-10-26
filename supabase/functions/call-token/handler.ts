// A LiveKit token for a masked call on the caller's own job (spec communication.voice_calls;
// Phase 6's seam, ERD §8). The database decides everything: `start_call`, run as the caller,
// works out the other party from the job, refuses outside the job window and resolves two people
// calling each other into one call. This function only signs a token for the room it returns.
//
// One action for both ends: whoever opens the call screen calls this. If the other person is
// already ringing them, `start_call` says so (`is_caller` false) and the call is answered here,
// so an incoming call needs no second code path in the app.

import { errorResponse, json } from "../_shared/http.ts";
import type { LiveKitCredentials, RoomToken } from "./token.ts";

export class RpcError extends Error {
  constructor(readonly code: string) {
    super(code);
  }
}

export interface CallTokenDeps {
  rpc(fn: string, args: Record<string, unknown>): Promise<unknown>;
  credentials: LiveKitCredentials | null;
  sign(credentials: LiveKitCredentials, room: string, identity: string): Promise<RoomToken>;
  log(level: "info" | "warn" | "error", event: string, fields?: Record<string, unknown>): void;
}

interface StartedCall {
  call_id: string;
  room_name: string;
  identity: string;
  counterparty_id: string;
  status: string;
  is_caller: boolean;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const STATUS_FOR: Record<string, number> = {
  ERR_CALL_WINDOW_CLOSED: 409,
  ERR_CALL_NOT_FOUND: 404,
  ERR_JOB_NOT_FOUND: 404,
  ERR_ILLEGAL_TRANSITION: 409,
  ERR_PERMISSION_DENIED: 403,
  ERR_IDEMPOTENCY_KEY_INVALID: 400,
  ERR_IDEMPOTENCY_KEY_REUSED: 409,
  ERR_UNAUTHENTICATED: 401,
};

export function createCallTokenHandler(deps: CallTokenDeps) {
  return async (req: Request): Promise<Response> => {
    if (req.method !== "POST") return errorResponse(405, "ERR_METHOD_NOT_ALLOWED");
    let body: { request_id?: unknown; idempotency_key?: unknown };
    try {
      body = await req.json();
    } catch {
      return errorResponse(400, "ERR_INVALID_ARGUMENT");
    }
    const requestId = typeof body.request_id === "string" ? body.request_id : "";
    const key = typeof body.idempotency_key === "string" ? body.idempotency_key : "";
    if (!UUID.test(requestId) || key.length < 16 || key.length > 100) {
      return errorResponse(400, "ERR_INVALID_ARGUMENT");
    }
    // Before start_call, not after: a call that rings the other person and then cannot connect
    // either of them is worse than a button that says calls are unavailable.
    if (!deps.credentials) return errorResponse(503, "ERR_FEATURE_UNAVAILABLE");

    try {
      const rows = await deps.rpc("start_call", { p_idempotency_key: key, p_request_id: requestId }) as StartedCall[];
      const call = rows?.[0];
      if (!call) return errorResponse(500, "ERR_INTERNAL");
      let status = call.status;
      if (!call.is_caller && call.status === "ringing") {
        // Answering is its own intent with its own key, derived so a retry answers once.
        status = String(await deps.rpc("answer_call", { p_idempotency_key: `${key}:answer`, p_call_id: call.call_id }));
      }
      const { token, expiresAt } = await deps.sign(deps.credentials, call.room_name, call.identity);
      deps.log("info", "call.token", { is_caller: call.is_caller, status });
      return json(
        {
          url: deps.credentials.url,
          token,
          expires_at: expiresAt.toISOString(),
          call_id: call.call_id,
          room_name: call.room_name,
          is_caller: call.is_caller,
          status,
        },
        200,
        { "cache-control": "no-store" },
      );
    } catch (err) {
      if (err instanceof RpcError) return errorResponse(STATUS_FOR[err.code] ?? 400, err.code);
      deps.log("error", "call.token_failed", { error: err instanceof Error ? err.name : "unknown" });
      return errorResponse(500, "ERR_INTERNAL");
    }
  };
}
