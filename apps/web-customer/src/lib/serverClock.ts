// Simulated server clock (mirrors ServerClock in suskii_core). The mock
// bootstrap calls syncServerClock() with its serverTime; every TTL
// (offers, payment windows, sessions) is computed and evaluated against
// serverNow(), never raw device time.

let offsetMs = 0;

/** Feed the bootstrap's serverTime here. */
export function syncServerClock(serverTime: Date): void {
  offsetMs = serverTime.getTime() - Date.now();
}

/** Current simulated server time (UTC instant as a Date). */
export function serverNow(): Date {
  return new Date(Date.now() + offsetMs);
}

/** Measured offset (server − device) in milliseconds. */
export function serverClockOffsetMs(): number {
  return offsetMs;
}
