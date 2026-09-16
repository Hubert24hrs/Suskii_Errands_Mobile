// Standard Webhooks verification (https://www.standardwebhooks.com), used by Supabase Auth
// HTTP hooks. Implemented on WebCrypto so shared code has no npm dependency; the test suite
// cross-checks it against the reference `standardwebhooks` library.
//
//   signed content  = `${webhook-id}.${webhook-timestamp}.${raw body}`
//   signature       = base64(HMAC-SHA256(secret, signed content))
//   header          = "v1,<signature>" entries separated by spaces

const TOLERANCE_SECONDS = 5 * 60;

export class WebhookVerificationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "WebhookVerificationError";
  }
}

// Supabase formats hook secrets as "v1,whsec_<base64>"; the reference library accepts
// "whsec_<base64>" or bare base64. All three are normalised to the raw key bytes.
export function decodeHookSecret(secret: string): Uint8Array<ArrayBuffer> {
  const base64 = secret.trim().replace(/^v1,/, "").replace(/^whsec_/, "");
  try {
    return Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
  } catch {
    throw new WebhookVerificationError("invalid webhook secret encoding");
  }
}

function toBase64(bytes: ArrayBuffer): string {
  return btoa(String.fromCharCode(...new Uint8Array(bytes)));
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export async function signWebhook(
  secret: string,
  id: string,
  timestampSeconds: number,
  body: string,
): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    decodeHookSecret(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const mac = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(`${id}.${timestampSeconds}.${body}`),
  );
  return `v1,${toBase64(mac)}`;
}

/**
 * Verifies a webhook and returns the parsed JSON body. `secrets` may hold several
 * secrets separated by "|" so a secret can be rotated without dropping requests.
 */
export async function verifyWebhook(
  rawBody: string,
  headers: Headers,
  secrets: string,
  nowSeconds: number = Math.floor(Date.now() / 1000),
): Promise<unknown> {
  const id = headers.get("webhook-id");
  const timestamp = headers.get("webhook-timestamp");
  const signatureHeader = headers.get("webhook-signature");
  if (!id || !timestamp || !signatureHeader) {
    throw new WebhookVerificationError("missing webhook headers");
  }

  const ts = Number(timestamp);
  if (!Number.isInteger(ts) || Math.abs(nowSeconds - ts) > TOLERANCE_SECONDS) {
    throw new WebhookVerificationError("webhook timestamp outside tolerance");
  }

  const presented = signatureHeader
    .split(" ")
    .filter((entry) => entry.startsWith("v1,"));

  for (const secret of secrets.split("|").filter((s) => s.trim() !== "")) {
    const expected = await signWebhook(secret, id, ts, rawBody);
    if (presented.some((sig) => timingSafeEqual(sig, expected))) {
      try {
        return JSON.parse(rawBody);
      } catch {
        throw new WebhookVerificationError("webhook body is not JSON");
      }
    }
  }
  throw new WebhookVerificationError("no matching webhook signature");
}
