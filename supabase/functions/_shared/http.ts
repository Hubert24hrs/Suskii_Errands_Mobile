export function json(body: unknown, status = 200, headers: HeadersInit = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", ...headers },
  });
}

/** Stable error body for client-facing functions: the code is what the apps localise. */
export function errorResponse(status: number, code: string): Response {
  return json({ error: { code } }, status);
}

/**
 * Error body for Supabase Auth hooks. Auth reads `error.http_code` and `error.message`
 * (Send SMS hook documentation).
 */
export function hookError(httpCode: number, message: string): Response {
  return json({ error: { http_code: httpCode, message } }, httpCode);
}
