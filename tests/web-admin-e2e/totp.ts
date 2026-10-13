// RFC 6238 TOTP (SHA-1, 30 s, 6 digits): what an authenticator app computes from the secret
// GoTrue shows at enrolment. Each code is used once: a second verification in the same 30 s
// step waits for the next one, as a person would.

import { createHmac } from 'node:crypto';

const STEP_MS = 30_000;

function base32(secret: string): Buffer {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  let bits = '';
  for (const char of secret.replace(/=+$/, '').toUpperCase()) {
    const value = alphabet.indexOf(char);
    if (value < 0) throw new Error(`not base32: ${char}`);
    bits += value.toString(2).padStart(5, '0');
  }
  const bytes: number[] = [];
  for (let i = 0; i + 8 <= bits.length; i += 8) bytes.push(Number.parseInt(bits.slice(i, i + 8), 2));
  return Buffer.from(bytes);
}

export function totp(secret: string, step: number): string {
  const counter = Buffer.alloc(8);
  counter.writeBigUInt64BE(BigInt(step));
  const hmac = createHmac('sha1', base32(secret)).update(counter).digest();
  const offset = hmac[hmac.length - 1]! & 0x0f;
  const code = (hmac.readUInt32BE(offset) & 0x7fffffff) % 1_000_000;
  return code.toString().padStart(6, '0');
}

const lastStep = new Map<string, number>();

/** A code for the current step that this secret has not used yet. */
export async function freshCode(secret: string): Promise<string> {
  let step = Math.floor(Date.now() / STEP_MS);
  if ((lastStep.get(secret) ?? -1) >= step) {
    await new Promise((resolve) => setTimeout(resolve, (step + 1) * STEP_MS - Date.now() + 250));
    step = Math.floor(Date.now() / STEP_MS);
  }
  lastStep.set(secret, step);
  return totp(secret, step);
}
