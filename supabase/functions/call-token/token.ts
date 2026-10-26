// LiveKit access tokens. Read 2026-10-26 from docs.livekit.io (Tokens & grants) and the official
// JavaScript server SDK (livekit/node-sdks, packages/livekit-server-sdk/src/AccessToken.ts):
//   HS256 over the API secret's UTF-8 bytes; `iss` the API key, `sub` the participant identity,
//   `nbf` now, `exp` the TTL; the room grant under `video` (`room`, `roomJoin`, `canPublish`,
//   `canSubscribe`, `canPublishData`, `canPublishSources` as strings such as "microphone").
// Expiry only gates the first connection, not reconnects, so a short TTL costs nothing.

import { SignJWT } from "jose";

export interface LiveKitCredentials {
  url: string;
  apiKey: string;
  apiSecret: string;
}

export interface RoomToken {
  token: string;
  expiresAt: Date;
}

/** Ten minutes: long enough to ring and answer, short enough that a leaked token is stale. */
export const TOKEN_TTL_S = 600;

export async function roomToken(
  credentials: LiveKitCredentials,
  room: string,
  identity: string,
  now: number = Date.now(),
): Promise<RoomToken> {
  const nowS = Math.floor(now / 1000);
  // Audio only: a masked call is a voice call. No camera, no screen, no data channel, and no
  // display name, because LiveKit advises against personal data in tokens and the app does not
  // need one to know who the other person on its own job is.
  const token = await new SignJWT({
    video: {
      room,
      roomJoin: true,
      canPublish: true,
      canSubscribe: true,
      canPublishData: false,
      canPublishSources: ["microphone"],
    },
  })
    .setProtectedHeader({ alg: "HS256", typ: "JWT" })
    .setIssuer(credentials.apiKey)
    .setSubject(identity)
    .setNotBefore(nowS)
    .setExpirationTime(nowS + TOKEN_TTL_S)
    .sign(new TextEncoder().encode(credentials.apiSecret));
  return { token, expiresAt: new Date((nowS + TOKEN_TTL_S) * 1000) };
}

export function credentialsFromEnv(get: (k: string) => string | undefined): LiveKitCredentials | null {
  const url = get("LIVEKIT_URL") ?? "";
  const apiKey = get("LIVEKIT_API_KEY") ?? "";
  const apiSecret = get("LIVEKIT_API_SECRET") ?? "";
  if (!/^wss:\/\/[a-z0-9.-]+$/i.test(url) || !apiKey || apiSecret.length < 16) return null;
  return { url, apiKey, apiSecret };
}
