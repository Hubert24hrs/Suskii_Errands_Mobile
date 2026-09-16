// SMS provider abstraction (spec: OTP via the Send SMS Hook with per-country routing).
// Vendor adapters (Termii, Africa's Talking, Infobip per the vendor matrix) are added when
// spike S-09 picks and measures them; their APIs are not written from memory.

export interface SmsSendResult {
  ok: boolean;
  /** Vendor message id when accepted. */
  messageId?: string;
  /** Stable, non-personal failure reason for logs and metrics. */
  reason?: string;
}

export interface SmsProvider {
  readonly name: string;
  send(toE164Digits: string, message: string, signal: AbortSignal): Promise<SmsSendResult>;
}

/**
 * Development provider: accepts every message and logs only that a message was sent.
 * Refuses to run in production so a misconfigured routing table fails loudly instead of
 * silently swallowing real users' OTPs.
 */
export class ConsoleSmsProvider implements SmsProvider {
  readonly name = "console";

  constructor(private readonly environment: string) {}

  send(_to: string, _message: string, _signal: AbortSignal): Promise<SmsSendResult> {
    if (this.environment === "production") {
      return Promise.resolve({ ok: false, reason: "console_provider_disabled_in_production" });
    }
    return Promise.resolve({ ok: true, messageId: `console-${crypto.randomUUID()}` });
  }
}

export type ProviderRegistry = ReadonlyMap<string, SmsProvider>;
