import type { ProviderRegistry, SmsSendResult } from "./provider.ts";

export interface Attempt {
  provider: string;
  ok: boolean;
  reason?: string;
  elapsedMs: number;
}

export interface FailoverResult {
  ok: boolean;
  provider?: string;
  messageId?: string;
  attempts: Attempt[];
}

/**
 * Tries providers in order until one accepts the message. Supabase Auth gives an HTTP hook
 * 5 s in total, so every attempt shares one deadline; a provider that would start with less
 * than `minAttemptMs` left is skipped rather than started and abandoned.
 */
export async function sendWithFailover(
  providerNames: string[],
  registry: ProviderRegistry,
  toE164Digits: string,
  message: string,
  options: { deadlineMs: number; minAttemptMs?: number; now?: () => number },
): Promise<FailoverResult> {
  const now = options.now ?? Date.now;
  const minAttemptMs = options.minAttemptMs ?? 800;
  const deadline = now() + options.deadlineMs;
  const attempts: Attempt[] = [];

  for (const name of providerNames) {
    const provider = registry.get(name);
    if (!provider) {
      attempts.push({ provider: name, ok: false, reason: "provider_not_registered", elapsedMs: 0 });
      continue;
    }
    const remaining = deadline - now();
    if (remaining < minAttemptMs) {
      attempts.push({ provider: name, ok: false, reason: "deadline_exhausted", elapsedMs: 0 });
      break;
    }

    const started = now();
    const signal = AbortSignal.timeout(remaining);
    let result: SmsSendResult;
    try {
      // Race the abort signal too: a provider that ignores it must not blow the hook budget.
      result = await Promise.race([
        provider.send(toE164Digits, message, signal),
        new Promise<SmsSendResult>((resolve) =>
          signal.addEventListener("abort", () => resolve({ ok: false, reason: "timeout" }), { once: true })
        ),
      ]);
    } catch (err) {
      const timedOut = err instanceof DOMException && err.name === "TimeoutError";
      result = { ok: false, reason: timedOut ? "timeout" : "exception" };
    }
    attempts.push({ provider: name, ok: result.ok, reason: result.reason, elapsedMs: now() - started });
    if (result.ok) {
      return { ok: true, provider: name, messageId: result.messageId, attempts };
    }
  }
  return { ok: false, attempts };
}
