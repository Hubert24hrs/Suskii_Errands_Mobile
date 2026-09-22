// Web-safe UUIDv7 idempotency keys (mirrors newIdempotencyKey() in
// suskii_core). Composed byte-by-byte from crypto.getRandomValues draws —
// no bitwise shifts over 32-bit boundaries.

/**
 * Returns an RFC 9562 UUIDv7: 48-bit Unix-ms timestamp, version 7,
 * variant 10, 74 random bits. One key per user intent; reuse the same key
 * only when retrying that same intent.
 */
export function newIdempotencyKey(): string {
  const bytes = globalThis.crypto.getRandomValues(new Uint8Array(16));
  const ms = Date.now();
  // 48-bit big-endian timestamp. Division + modulo stay in safe-integer
  // range; no >32-bit shifts.
  bytes[0] = Math.floor(ms / 2 ** 40) % 256;
  bytes[1] = Math.floor(ms / 2 ** 32) % 256;
  bytes[2] = Math.floor(ms / 2 ** 24) % 256;
  bytes[3] = Math.floor(ms / 2 ** 16) % 256;
  bytes[4] = Math.floor(ms / 2 ** 8) % 256;
  bytes[5] = ms % 256;
  bytes[6] = (bytes[6] & 0x0f) | 0x70; // version 7
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10
  const hex = Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
  return (
    `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-` +
    `${hex.slice(16, 20)}-${hex.slice(20)}`
  );
}
