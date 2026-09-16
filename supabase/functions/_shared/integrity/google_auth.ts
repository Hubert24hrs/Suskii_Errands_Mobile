// OAuth 2.0 access tokens for a Google service account (JWT bearer grant, RFC 7523), used to
// call the Play Integrity API from outside Google Cloud. The key JSON lives in GCP Secret
// Manager and reaches the function as an Edge Function secret (infra-cicd.md §4).

import { importPKCS8, SignJWT } from "jose";

export interface ServiceAccountKey {
  client_email: string;
  private_key: string;
  token_uri?: string;
}

export function createGoogleAccessTokenSource(
  key: ServiceAccountKey,
  scope: string,
  fetchImpl: typeof fetch = fetch,
  now: () => number = Date.now,
): () => Promise<string> {
  let cached: { token: string; expiresAt: number } | null = null;
  const tokenUri = key.token_uri ?? "https://oauth2.googleapis.com/token";

  return async () => {
    if (cached && cached.expiresAt - 60_000 > now()) return cached.token;

    const iat = Math.floor(now() / 1000);
    const assertion = await new SignJWT({ scope })
      .setProtectedHeader({ alg: "RS256", typ: "JWT" })
      .setIssuer(key.client_email)
      .setAudience(tokenUri)
      .setIssuedAt(iat)
      .setExpirationTime(iat + 3600)
      .sign(await importPKCS8(key.private_key, "RS256"));

    const res = await fetchImpl(tokenUri, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
        assertion,
      }),
      signal: AbortSignal.timeout(5_000),
    });
    if (!res.ok) throw new Error(`google_token_http_${res.status}`);
    const body = await res.json() as { access_token: string; expires_in: number };
    cached = { token: body.access_token, expiresAt: now() + body.expires_in * 1000 };
    return body.access_token;
  };
}
