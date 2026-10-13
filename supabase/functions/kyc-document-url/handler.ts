// A 60-second link to one KYC document, for a verification officer.
//
// `kyc-docs` is write-only for every client role, so an officer cannot sign a URL with their own
// token. The order is the point: `request_document_access` runs first, **as the officer**, so the
// database decides (aal2, a TOTP code in the last five minutes, role, not their own folder) and writes `audit.kyc_access` before any
// URL exists. Only then does the service role sign, for that one path, for sixty seconds.

import { errorResponse, json } from "../_shared/http.ts";

export const DOCUMENT_URL_TTL_SECONDS = 60;

export type DocumentUrlDeps = {
  /** `request_document_access` as the caller; returns the path, or raises the wire code. */
  requestAccess(uploadRef: string, reasonCode: string): Promise<string>;
  /** A signed URL for `kyc-docs/<path>`, valid for `ttlSeconds`. */
  sign(path: string, ttlSeconds: number): Promise<string>;
  now(): number;
  log(level: "info" | "warn" | "error", message: string, fields?: Record<string, unknown>): void;
};

/** A wire code raised by the database, recovered from the message PostgREST forwards. */
export class AccessRefusedError extends Error {
  constructor(readonly code: string) {
    super(code);
  }
}

// `<user id>/<file>`: a folder and one name, nothing that climbs out of it.
const UPLOAD_REF = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\/[A-Za-z0-9._-]{1,200}$/;
const REASON = /^[a-z0-9_]{3,60}$/;

const STATUS_FOR: Record<string, number> = {
  ERR_UNAUTHENTICATED: 401,
  // The officer's code is older than five minutes: verify a fresh one and ask again (Z.11).
  ERR_REAUTH_REQUIRED: 401,
  ERR_PERMISSION_DENIED: 403,
  ERR_INVALID_ARGUMENT: 400,
};

export function createDocumentUrlHandler(deps: DocumentUrlDeps) {
  return async (req: Request): Promise<Response> => {
    if (req.method !== "POST") return errorResponse(405, "ERR_METHOD_NOT_ALLOWED");
    let body: { upload_ref?: unknown; reason_code?: unknown };
    try {
      body = await req.json();
    } catch {
      return errorResponse(400, "ERR_INVALID_ARGUMENT");
    }
    const uploadRef = body.upload_ref;
    const reasonCode = body.reason_code;
    if (
      typeof uploadRef !== "string" || !UPLOAD_REF.test(uploadRef) || uploadRef.includes("..") ||
      typeof reasonCode !== "string" || !REASON.test(reasonCode)
    ) {
      return errorResponse(400, "ERR_INVALID_ARGUMENT");
    }

    let path: string;
    try {
      path = await deps.requestAccess(uploadRef, reasonCode);
    } catch (err) {
      if (err instanceof AccessRefusedError) {
        return errorResponse(STATUS_FOR[err.code] ?? 403, err.code);
      }
      deps.log("error", "kyc_document_url.access_failed");
      return errorResponse(500, "ERR_INTERNAL");
    }
    // The database answers with the path it audited; sign that and nothing else.
    if (path !== uploadRef) {
      deps.log("error", "kyc_document_url.path_mismatch");
      return errorResponse(500, "ERR_INTERNAL");
    }

    try {
      const url = await deps.sign(path, DOCUMENT_URL_TTL_SECONDS);
      const expiresAt = new Date(deps.now() + DOCUMENT_URL_TTL_SECONDS * 1000).toISOString();
      // Never cached: the URL is a capability, and a cached copy outlives its sixty seconds.
      return json({ url, expires_at: expiresAt }, 200, { "cache-control": "no-store" });
    } catch {
      deps.log("error", "kyc_document_url.sign_failed");
      return errorResponse(500, "ERR_INTERNAL");
    }
  };
}
