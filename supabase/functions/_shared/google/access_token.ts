// OAuth2 access tokens for a Google service account, by the JWT-bearer grant
// (developers.google.com/identity/protocols/oauth2/service-account, read 2026-10-26): sign a JWT
// with the account's key, exchange it at `token_uri`, cache it until a minute before it expires.
// Used by FCM (push) and Vertex AI (the concierge), each with its own account and scope.

import { importPKCS8, SignJWT } from "jose";

export interface ServiceAccount {
  project_id: string;
  client_email: string;
  private_key: string;
  token_uri: string;
}

export function parseServiceAccount(json: string): ServiceAccount {
  const raw = JSON.parse(json) as Partial<ServiceAccount>;
  for (const k of ["project_id", "client_email", "private_key", "token_uri"] as const) {
    if (typeof raw[k] !== "string" || raw[k] === "") throw new Error(`service account: missing ${k}`);
  }
  return raw as ServiceAccount;
}

export class ServiceAccountTokens {
  private token?: { value: string; expiresAt: number };
  private readonly fetchFn: typeof fetch;
  private readonly now: () => number;

  constructor(
    private readonly account: ServiceAccount,
    private readonly scope: string,
    options: { fetch?: typeof fetch; now?: () => number } = {},
  ) {
    this.fetchFn = options.fetch ?? fetch;
    this.now = options.now ?? Date.now;
  }

  async get(signal?: AbortSignal): Promise<string> {
    const nowS = Math.floor(this.now() / 1000);
    if (this.token && this.token.expiresAt - 60 > nowS) return this.token.value;

    const key = await importPKCS8(this.account.private_key, "RS256");
    const assertion = await new SignJWT({ scope: this.scope })
      .setProtectedHeader({ alg: "RS256", typ: "JWT" })
      .setIssuer(this.account.client_email)
      .setAudience(this.account.token_uri)
      .setIssuedAt(nowS)
      .setExpirationTime(nowS + 3600)
      .sign(key);

    const response = await this.fetchFn(this.account.token_uri, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion }),
      signal,
    });
    if (!response.ok) throw new Error(`token exchange failed: ${response.status}`);
    const body = await response.json() as { access_token?: string; expires_in?: number };
    if (!body.access_token) throw new Error("token exchange returned no access token");
    this.token = { value: body.access_token, expiresAt: nowS + (body.expires_in ?? 3600) };
    return body.access_token;
  }
}
